package mth.core.server

import mth.core.*

private typealias TC = TelnetCommand
private typealias TO = TelnetOption
private typealias TS = TelnetSub

/**
 * A single server-side telnet session, managing protocol negotiation state.
 *
 * Replaces the C `mth_data` struct and the `translate_telopts` function.
 * Each instance corresponds to one client connection.
 */
class TelnetSession(
    var delegate: TelnetSessionDelegate? = null,
    val telnetTable: List<TelnetOptionEntry> = defaultTelnetTable,
    val msdpTable: List<MSDPVariableDefinition> = defaultMSDPTable
) {
    // -- Public State --

    var ttypeTerminalType: String = ""
        private set
    var ttypeMTTSFlags: MTTSFlags = MTTSFlags()
        private set
    var windowSize: Pair<Int, Int> = Pair(0, 0)
        private set
    var baseCommFlags: CommFlags = CommFlags()
        private set
    private var restoredProxy = ""
    val proxy: String get() = environment.ipAddress ?: restoredProxy
    var environment = MNESEnvironment()
        private set
    var newEnvironEnabled = false
        private set
    var hasTTYPEMTTS = false
        private set
    val hasMTTS: Boolean get() = environment.mtts != null || hasTTYPEMTTS
    /** MNES terminal type, falling back to the first TTYPE report. */
    val terminalType: String get() = environment.terminalType ?: ttypeTerminalType
    /** MNES MTTS report, falling back to TTYPE MTTS. Use [commFlags] for charset-aware UTF-8 support. */
    val mttsFlags: MTTSFlags get() = environment.mtts?.let { MTTSFlags(it) } ?: ttypeMTTSFlags
    /** Effective flags: MNES MTTS overrides base capabilities; MNES CHARSET overrides the UTF-8 bit. */
    val commFlags: CommFlags get() {
        var flags = baseCommFlags
        if (MTTSFlags.UTF8 in ttypeMTTSFlags) flags = flags.insert(CommFlags.UTF8)
        if (MTTSFlags.COLORS_256 in ttypeMTTSFlags) flags = flags.insert(CommFlags.COLORS_256)
        environment.mtts?.let {
            flags = flags.remove(CommFlags.UTF8).remove(CommFlags.COLORS_256)
            if (it and MTTSFlags.UTF8.rawValue != 0) flags = flags.insert(CommFlags.UTF8)
            if (it and MTTSFlags.COLORS_256.rawValue != 0) flags = flags.insert(CommFlags.COLORS_256)
        }
        environment.charset?.let {
            flags = flags.remove(CommFlags.UTF8)
            if (it == "UTF-8") flags = flags.insert(CommFlags.UTF8)
        }
        return flags
    }

    fun restoreEnvironment(environment: MNESEnvironment, enabled: Boolean, hasTTYPEMTTS: Boolean) {
        this.restoredProxy = ""
        this.environment = environment.validated
        this.newEnvironEnabled = enabled
        this.hasTTYPEMTTS = hasTTYPEMTTS
    }

    fun requestEnvironment() {
        if (newEnvironEnabled) {
            write(NewEnviron.packet(TS.ENV_SEND, emptyList()))
            write(NewEnviron.packet(TS.ENV_SEND, listOf(NewEnviron.Entry("SYSTEMTYPE"))))
        } else write(byteArrayOf(TC.IAC, TC.DO, TO.NEW_ENVIRON))
    }

    fun renegotiateEnvironment() {
        disableEnvironment()
        write(byteArrayOf(TC.IAC, TC.DONT, TO.NEW_ENVIRON))
        write(byteArrayOf(TC.IAC, TC.DO, TO.NEW_ENVIRON))
    }

    private fun disableEnvironment() {
        restoredProxy = ""
        newEnvironEnabled = false
        val previous = environment
        environment = MNESEnvironment()
        if (previous != environment) delegate?.telnetSessionEnvironmentChanged(this, environment)
    }

    /** The MSDP manager for this session. Created lazily when MSDP/GMCP is negotiated. */
    var msdpManager: MSDPManager? = null
        private set

    /** Whether MCCP2 compression is active for outbound data. */
    val isMCCP2Active: Boolean get() = mccp2 != null

    /** Whether MCCP3 decompression is active for inbound data. */
    val isMCCP3Active: Boolean get() = mccp3 != null

    // -- Private State --

    /** Buffer for incomplete telnet sequences (packet fragmentation). */
    private var telbuf: MutableList<Byte> = mutableListOf()
    private var oversizedEnvironmentIAC: Boolean? = null

    /** MCCP2 deflate stream (server->client output compression). */
    private var mccp2: DeflateStream? = null

    /** MCCP3 inflate stream (client->server input decompression). */
    private var mccp3: InflateStream? = null

    // -- Restore Constructor --

    /**
     * Restore a TelnetSession from saved copyover state.
     * Sets negotiated flags directly without sending announcements to the client.
     */
    constructor(
        restoringCommFlags: CommFlags,
        mttsFlags: MTTSFlags,
        terminalType: String,
        windowSize: Pair<Int, Int>,
        proxy: String,
        delegate: TelnetSessionDelegate? = null,
        telnetTable: List<TelnetOptionEntry> = defaultTelnetTable,
        msdpTable: List<MSDPVariableDefinition> = defaultMSDPTable
    ) : this(delegate, telnetTable, msdpTable) {
        this.baseCommFlags = restoringCommFlags
        this.ttypeMTTSFlags = mttsFlags
        this.hasTTYPEMTTS = mttsFlags.rawValue != 0
        this.ttypeTerminalType = terminalType
        this.windowSize = windowSize
        this.restoredProxy = proxy.takeIf { MNESEnvironment.isIPAddress(it) } ?: ""
    }

    // -- Connection Lifecycle --

    /** Announce support for negotiated telnet options. Call once after connection is established. */
    fun announceSupport() {
        for (i in 0 until minOf(telnetTable.size, 255)) {
            val entry = telnetTable[i]
            if (!entry.announce.isEmpty()) {
                if (AnnounceFlags.WILL in entry.announce) {
                    write(byteArrayOf(TC.IAC, TC.WILL, i.toByte()))
                }
                if (AnnounceFlags.DO in entry.announce) {
                    write(byteArrayOf(TC.IAC, TC.DO, i.toByte()))
                }
            }
        }
    }

    /** Unannounce support (e.g. before copyover). */
    fun unannounceSupport() {
        disableEnvironment()
        endMCCP2()
        endMCCP3()
        for (i in 0 until minOf(telnetTable.size, 255)) {
            val entry = telnetTable[i]
            if (!entry.announce.isEmpty()) {
                if (AnnounceFlags.WILL in entry.announce) {
                    write(byteArrayOf(TC.IAC, TC.WONT, i.toByte()))
                }
                if (AnnounceFlags.DO in entry.announce) {
                    write(byteArrayOf(TC.IAC, TC.DONT, i.toByte()))
                }
            }
        }
    }

    /** Re-send IAC WILL GMCP to the client. */
    fun reannounceGMCP() {
        write(byteArrayOf(TC.IAC, TC.WILL, TO.GMCP))
    }

    /** Whether the client negotiated MXP (telnet option 91). */
    val mxpEnabled: Boolean get() = CommFlags.MXP in baseCommFlags

    /** Re-assert MXP after a copyover restore: resends the start command and the
     * locked-default line mode. */
    fun reassertMXP() {
        if (CommFlags.MXP in baseCommFlags) {
            write(MXP_START)
            write(MXP_LOCKED_DEFAULT)
        }
    }

    /** Send echo-off (password mode). */
    fun sendEchoOff() {
        baseCommFlags = baseCommFlags.insert(CommFlags.PASSWORD)
        write(byteArrayOf(TC.IAC, TC.WILL, TO.ECHO))
    }

    /** Send echo-on (normal mode). */
    fun sendEchoOn() {
        baseCommFlags = baseCommFlags.remove(CommFlags.PASSWORD)
        write(byteArrayOf(TC.IAC, TC.WONT, TO.ECHO))
    }

    /** Send End-of-Record marker (prompt marker). */
    fun sendEOR() {
        if (CommFlags.EOR in baseCommFlags) {
            write(byteArrayOf(TC.IAC, TC.EOR))
        }
    }

    /** Send MSDP update if needed. Call periodically (e.g. each tick). */
    fun flushMSDPUpdates() {
        msdpManager?.flushUpdates()
    }

    /** Send a GMCP packet with the given module name and JSON payload. */
    fun sendGMCP(module: String, json: String) {
        if (CommFlags.GMCP !in baseCommFlags) return
        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.GMCP)
        packet.addAll(module.toByteArray(Charsets.UTF_8).toList())
        packet.add(' '.code.toByte())
        packet.addAll(json.toByteArray(Charsets.UTF_8).toList())
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    /** Send an MSP trigger as a telnet subnegotiation (IAC SB MSP ... IAC SE). */
    fun sendMSP(payload: String) {
        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.MSP)
        packet.addAll(payload.toByteArray(Charsets.UTF_8).toList())
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    // -- Input Processing --

    /**
     * Process raw input from the client. Strips telnet negotiations,
     * handles \r\0 -> \n conversion, and returns clean text.
     */
    fun processInput(src: ByteArray): ByteArray {
        var input = src

        // MCCP3: decompress incoming data if active
        val inflater = mccp3
        if (inflater != null) {
            val result = inflater.decompress(input)
            if (result == null) {
                log("MCCP3: Compression error, disabling MCCP3.")
                write(byteArrayOf(TC.IAC, TC.DONT, TO.MCCP3))
                endMCCP3()
                return ByteArray(0)
            }
            if (result.finished) {
                log("MCCP3: Compression end, disabling MCCP3.")
                endMCCP3()
                // Decompressed data + any trailing uncompressed data
                input = result.decompressed + result.unconsumedInput
            } else {
                input = result.decompressed
            }
        }

        val out = mutableListOf<Byte>()

        // Reassemble fragmented packets
        if (telbuf.isNotEmpty()) {
            val combined = ByteArray(telbuf.size + input.size)
            telbuf.toByteArray().copyInto(combined)
            input.copyInto(combined, telbuf.size)
            input = combined
            telbuf.clear()
        }

        var i = 0

        while (i < input.size) {
            val pendingIAC = oversizedEnvironmentIAC
            if (pendingIAC != null) {
                oversizedEnvironmentIAC = if (pendingIAC) { if (input[i] == TC.SE) null else false } else input[i] == TC.IAC
                i++
                continue
            }
            when (input[i]) {
                TC.IAC -> {
                    val remaining = input.size - i

                    // Try to match against the telopt dispatch table
                    val (skip, matched) = dispatchTelopt(input, i, remaining)

                    if (!matched && remaining > 1) {
                        // No handler matched -- handle generic telnet commands
                        val genericSkip = handleGenericTelnet(input, i, remaining, out)
                        if (genericSkip <= remaining) {
                            i += genericSkip
                        } else {
                            // Incomplete -- buffer for next call
                            telbuf = input.copyOfRange(i, input.size).toMutableList()
                            return out.toByteArray()
                        }
                    } else if (skip <= remaining) {
                        i += skip
                    } else {
                        // Incomplete telnet sequence -- buffer for next call
                        telbuf = input.copyOfRange(i, input.size).toMutableList()
                        return out.toByteArray()
                    }
                }
                0x0D.toByte() -> { // \r
                    if (i + 1 < input.size && input[i + 1] == 0x00.toByte()) {
                        out.add(0x0A.toByte()) // \r\0 -> \n
                    }
                    // \r alone or \r\n -- skip \r, let \n be handled next iteration
                    i++
                }
                0x00.toByte() -> { // \0
                    i++
                }
                else -> {
                    out.add(input[i])
                    i++
                }
            }
        }

        return out.toByteArray()
    }

    // -- Telopt Dispatch --

    private data class TeloptPattern(
        val pattern: ByteArray,
        val handler: (TelnetSession, ByteArray, Int, Int) -> Int
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is TeloptPattern) return false
            return pattern.contentEquals(other.pattern)
        }

        override fun hashCode(): Int = pattern.contentHashCode()
    }

    /**
     * Try to match input at position against known telopt patterns.
     * Returns (skip count, matched).
     */
    private fun dispatchTelopt(src: ByteArray, i: Int, remaining: Int): Pair<Int, Boolean> {
        for (entry in teloptPatterns) {
            if (remaining < entry.pattern.size) {
                // Check if it's a partial match (incomplete packet)
                if (isPartialMatch(src, i, remaining, entry.pattern)) {
                    return Pair(entry.pattern.size, true) // signal incomplete
                }
            } else {
                if (matchesPattern(src, i, entry.pattern)) {
                    val skip = entry.handler(this, src, i, remaining)
                    return Pair(skip, true)
                }
            }
        }
        return Pair(2, false) // no match
    }

    private fun matchesPattern(src: ByteArray, offset: Int, pattern: ByteArray): Boolean {
        if (offset + pattern.size > src.size) return false
        for (k in pattern.indices) {
            if (src[offset + k] != pattern[k]) return false
        }
        return true
    }

    private fun isPartialMatch(src: ByteArray, offset: Int, remaining: Int, pattern: ByteArray): Boolean {
        for (k in 0 until remaining) {
            if (src[offset + k] != pattern[k]) return false
        }
        return true
    }

    /** Lazily built telopt pattern table. */
    private val teloptPatterns: List<TeloptPattern> by lazy { buildTeloptPatterns() }

    private fun buildTeloptPatterns(): List<TeloptPattern> {
        return listOf(
            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.EOR))
                { s, _, _, _ -> s.processDoEOR(); 3 },

            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.TTYPE))
                { s, _, _, _ -> s.processWillTtype(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS))
                { s, src, i, n -> s.processSbTtypeIs(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.NAWS))
                { s, src, i, n -> s.processSbNaws(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.NEW_ENVIRON))
                { s, _, _, _ -> s.processWillNewEnviron(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.WONT, TO.NEW_ENVIRON))
                { s, _, _, _ -> s.disableEnvironment(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.NEW_ENVIRON))
                { s, src, i, n -> s.processSbNewEnviron(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.CHARSET))
                { s, _, _, _ -> s.processDoCharset(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.CHARSET))
                { s, src, i, n -> s.processSbCharset(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.MSSP))
                { s, _, _, _ -> s.processDoMssp(); 3 },

            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.MSDP))
                { s, _, _, _ -> s.processDoMsdp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MSDP))
                { s, src, i, n -> s.processSbMsdp(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.GMCP))
                { s, _, _, _ -> s.processDoGmcp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.GMCP))
                { s, src, i, n -> s.processSbGmcp(src, i, n) },

            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.MXP))
                { s, _, _, _ -> s.processDoMxp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.DONT, TO.MXP))
                { s, _, _, _ -> s.processDontMxp(); 3 },

            // MCCP2
            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.MCCP2))
                { s, _, _, _ -> s.processDoMccp2(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.DONT, TO.MCCP2))
                { s, _, _, _ -> s.processDontMccp2(); 3 },

            // MCCP3
            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.MCCP3))
                { _, _, _, _ -> 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MCCP3, TC.IAC, TC.SE))
                { s, _, _, _ -> s.processSbMccp3(); 5 },
        )
    }

    /**
     * Handle generic telnet commands that don't match any specific pattern.
     */
    private fun handleGenericTelnet(src: ByteArray, i: Int, remaining: Int, out: MutableList<Byte>): Int {
        if (remaining <= 1) return remaining + 1 // incomplete

        return when (src[i + 1]) {
            TC.WILL, TC.DO, TC.WONT, TC.DONT -> 3
            TC.SB -> skipSB(src, i, remaining)
            TC.IAC -> {
                // IAC IAC -> literal 0xFF
                out.add(TC.IAC)
                2
            }
            else -> {
                if (TelnetCommand.isCommand(src[i + 1])) 2 else 1
            }
        }
    }

    // -- Subnegotiation Helpers --

    /** Find the end of a subnegotiation (IAC SE). Returns skip count, or remaining+1 if incomplete. */
    private fun skipSB(src: ByteArray, offset: Int, srclen: Int): Int {
        val end = offset + srclen
        var j = offset + 1
        while (j < end) {
            if (src[j] == TC.SE && j > offset && src[j - 1] == TC.IAC) {
                return j - offset + 1
            }
            j++
        }
        return srclen + 1 // incomplete
    }

    // -- Output --

    /**
     * Send output data to the client, compressing via MCCP2 if active.
     */
    fun sendOutput(data: ByteArray) {
        write(data)
    }

    private fun write(data: ByteArray) {
        val compressor = mccp2
        if (compressor != null) {
            val compressed = compressor.compress(data)
            if (compressed != null) {
                delegate?.telnetSessionWrite(this, compressed)
            }
        } else {
            delegate?.telnetSessionWrite(this, data)
        }
    }

    /** Write data bypassing MCCP2 compression (used for the MCCP2 start marker). */
    private fun writeRaw(data: ByteArray) {
        delegate?.telnetSessionWrite(this, data)
    }

    private fun log(message: String) {
        delegate?.telnetSessionLog(this, message)
    }

    // -- Handler: EOR --

    private fun processDoEOR() {
        baseCommFlags = baseCommFlags.insert(CommFlags.EOR)
    }

    // -- Handler: Terminal Type --

    private fun processWillTtype() {
        if (ttypeTerminalType.isEmpty()) {
            // Request terminal type 3 times for MTTS detection, then reset
            val request = byteArrayOf(TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE)
            write(request)
            write(request)
            write(request)
            write(byteArrayOf(TC.IAC, TC.DONT, TO.TTYPE))
        }
    }

    private fun processSbTtypeIs(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        // Extract terminal type value from: IAC SB TTYPE IS <value> IAC SE
        val buf = mutableListOf<Byte>()
        var j = offset + 4
        val end = offset + srclen
        while (j < end) {
            if (src[j] == TC.IAC) break
            buf.add(src[j])
            j++
        }
        val value = String(buf.toByteArray(), Charsets.UTF_8)

        if (ttypeTerminalType.isEmpty()) {
            ttypeTerminalType = value
        } else {
            // Check for MTTS flags
            if (value.uppercase().startsWith("MTTS ")) {
                val flagStr = value.substring(5).trim()
                val flags = flagStr.toIntOrNull()
                if (flags != null) {
                    hasTTYPEMTTS = true
                    ttypeMTTSFlags = MTTSFlags(flags)

                    if (MTTSFlags.COLORS_256 in ttypeMTTSFlags) {
                        baseCommFlags = baseCommFlags.insert(CommFlags.COLORS_256)
                    }
                    if (MTTSFlags.UTF8 in ttypeMTTSFlags) {
                        baseCommFlags = baseCommFlags.insert(CommFlags.UTF8)
                    }
                }
            }

            // Detect 256-color terminals by name
            val upper = value.uppercase()
            if (upper.contains("-256COLOR") || upper == "XTERM") {
                baseCommFlags = baseCommFlags.insert(CommFlags.COLORS_256)
            }
        }

        return sbLen
    }

    // -- Handler: NAWS --

    private fun processSbNaws(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        // NAWS data starts at offset+3: 2 bytes cols (big-endian), 2 bytes rows
        // IAC bytes are doubled (stuffed) in NAWS values
        var cols = 0
        var rows = 0
        var j = offset + 3
        val end = offset + srclen

        // Parse 4 value bytes with IAC stuffing
        for (field in 0 until 4) {
            if (j >= end) break
            val byte = src[j].toInt() and 0xFF
            if (src[j] == TC.IAC && j + 1 < end) {
                j++ // skip stuffed IAC
            }
            j++

            when (field) {
                0 -> cols += byte * 256
                1 -> cols += byte
                2 -> rows += byte * 256
                3 -> rows += byte
            }
        }

        windowSize = Pair(cols, rows)
        return sbLen
    }

    // -- Handler: NEW-ENVIRON --

    private fun processWillNewEnviron() {
        if (newEnvironEnabled) return
        newEnvironEnabled = true
        requestEnvironment()
    }

    private fun processSbNewEnviron(src: ByteArray, offset: Int, srclen: Int): Int {
        val length = NewEnviron.frameLength(src, offset) ?: run {
            if (srclen > 8192) {
                oversizedEnvironmentIAC = src.reversed().takeWhile { it == TC.IAC }.size % 2 == 1
                return srclen
            }
            return srclen + 1
        }
        if (!newEnvironEnabled) return length
        val message = NewEnviron.decode(src.copyOfRange(offset, offset + length)) ?: return length
        if (message.command != TS.ENV_IS && message.command != TS.ENV_INFO) return length
        val previous = environment
        if (message.entries.any { it.name == "IPADDRESS" }) restoredProxy = ""
        environment = environment.apply(message.entries)
        for (entry in message.entries) {
            if (entry.name.equals("SYSTEMTYPE", ignoreCase = true) && entry.value.equals("WIN32", ignoreCase = true) && ttypeTerminalType.equals("ANSI", ignoreCase = true)) {
                baseCommFlags = baseCommFlags.insert(CommFlags.REMOTE_ECHO)
                ttypeTerminalType = "WINDOWS TELNET"
            }
        }
        if (previous != environment) delegate?.telnetSessionEnvironmentChanged(this, environment)
        return length
    }

    // -- Handler: CHARSET --

    private fun processDoCharset() {
        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.CHARSET)
        packet.add(TS.CHARSET_REQUEST)
        packet.add(' '.code.toByte())
        packet.addAll("UTF-8".toByteArray(Charsets.UTF_8).toList())
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    private fun processSbCharset(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        val subCommand = src[offset + 3]
        val separator = src[offset + 4]
        var j = offset + 5
        val end = offset + srclen

        while (j < end && src[j] != TC.SE && src[j] != separator) {
            val buf = mutableListOf<Byte>()
            while (j < end && src[j] != separator && src[j] != TC.IAC) {
                buf.add(src[j])
                j++
            }
            val charset = String(buf.toByteArray(), Charsets.UTF_8)

            if (subCommand == TS.CHARSET_ACCEPTED) {
                if (charset.equals("UTF-8", ignoreCase = true)) {
                    baseCommFlags = baseCommFlags.insert(CommFlags.UTF8)
                }
            } else if (subCommand == TS.CHARSET_REJECTED) {
                if (charset.equals("UTF-8", ignoreCase = true)) {
                    baseCommFlags = baseCommFlags.remove(CommFlags.UTF8)
                }
            }
            j++
        }

        return sbLen
    }

    // -- Handler: MSSP --

    private fun processDoMssp() {
        val d = delegate ?: return
        val pairs = d.telnetSessionMSSPData(this)

        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.MSSP)
        for (pair in pairs) {
            packet.add(TS.MSSP_VAR)
            packet.addAll(pair.first.toByteArray(Charsets.UTF_8).toList())
            packet.add(TS.MSSP_VAL)
            packet.addAll(pair.second.toByteArray(Charsets.UTF_8).toList())
        }
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    // -- Handler: MSDP --

    private fun processDoMsdp() {
        if (msdpManager != null) return
        initializeMSDP()
        log("INFO MSDP INITIALIZED")
    }

    /** Initialize MSDP manager for copyover restore (no negotiation announcements). */
    fun initializeMSDPForRestore(usesGMCP: Boolean) {
        if (msdpManager != null) return
        initializeMSDP()
        msdpManager?.usesGMCP = usesGMCP
    }

    private fun initializeMSDP() {
        msdpManager = MSDPManager(
            table = msdpTable,
            writeHandler = { data -> write(data) },
            logHandler = { message -> log(message) }
        )
        msdpManager?.usesGMCP = CommFlags.GMCP in baseCommFlags
        msdpManager?.updateVariable("SPECIFICATION", "http://tintin.sourceforge.net/msdp")
    }

    private fun processSbMsdp(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        val mgr = msdpManager ?: return sbLen

        var varName = ""
        var j = offset + 3
        val end = offset + srclen

        while (j < end && src[j] != TC.SE) {
            when (src[j]) {
                1.toByte() -> { // MSDP_VAR
                    j++
                    val buf = mutableListOf<Byte>()
                    while (j < end && src[j] != 2.toByte() && src[j] != TC.IAC) {
                        buf.add(src[j])
                        j++
                    }
                    varName = String(buf.toByteArray(), Charsets.UTF_8)
                }
                2.toByte() -> { // MSDP_VAL
                    j++
                    val buf = mutableListOf<Byte>()
                    var nest = 0
                    while (j < end && src[j] != TC.IAC) {
                        if (src[j] == 3.toByte() || src[j] == 5.toByte()) { // TABLE_OPEN or ARRAY_OPEN
                            nest++
                        } else if (src[j] == 4.toByte() || src[j] == 6.toByte()) { // TABLE_CLOSE or ARRAY_CLOSE
                            nest--
                        } else if (nest == 0 && (src[j] == 1.toByte() || src[j] == 2.toByte())) { // VAR or VAL
                            break
                        }
                        buf.add(src[j])
                        j++
                    }
                    val valStr = String(buf.toByteArray(), Charsets.UTF_8)
                    if (nest == 0) {
                        mgr.processVarVal(varName, valStr)
                    }
                }
                else -> {
                    j++
                }
            }
        }

        return sbLen
    }

    // -- Handler: MXP --

    private fun processDoMxp() {
        if (CommFlags.MXP in baseCommFlags) return
        baseCommFlags = baseCommFlags.insert(CommFlags.MXP)
        write(MXP_START)
        write(MXP_LOCKED_DEFAULT)
        log("INFO MXP ENABLED")
    }

    private fun processDontMxp() {
        baseCommFlags = baseCommFlags.remove(CommFlags.MXP)
    }

    // -- Handler: GMCP --

    private fun processDoGmcp() {
        baseCommFlags = baseCommFlags.insert(CommFlags.GMCP)
        if (msdpManager != null) {
            msdpManager?.usesGMCP = true
            log("INFO GMCP ENABLED (MSDP already active)")
            return
        }
        log("INFO MSDP OVER GMCP INITIALIZED")
        initializeMSDP()
    }

    private fun processSbGmcp(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        // Convert JSON to MSDP and process
        val gmcpPacket = src.copyOfRange(offset, offset + srclen)
        val msdpPacket = json2msdp(gmcpPacket)

        // Process the converted MSDP packet
        val mgr = msdpManager
        if (mgr != null) {
            var varName = ""
            var j = 3 // skip IAC SB MSDP
            while (j < msdpPacket.size) {
                if (msdpPacket[j] == TC.IAC) break
                when (msdpPacket[j]) {
                    1.toByte() -> { // MSDP_VAR
                        j++
                        val buf = mutableListOf<Byte>()
                        while (j < msdpPacket.size && msdpPacket[j] != 2.toByte() && msdpPacket[j] != TC.IAC) {
                            buf.add(msdpPacket[j])
                            j++
                        }
                        varName = String(buf.toByteArray(), Charsets.UTF_8)
                    }
                    2.toByte() -> { // MSDP_VAL
                        j++
                        val buf = mutableListOf<Byte>()
                        var nest = 0
                        while (j < msdpPacket.size && msdpPacket[j] != TC.IAC) {
                            if (msdpPacket[j] == 3.toByte() || msdpPacket[j] == 5.toByte()) { nest++ }
                            else if (msdpPacket[j] == 4.toByte() || msdpPacket[j] == 6.toByte()) { nest-- }
                            else if (nest == 0 && (msdpPacket[j] == 1.toByte() || msdpPacket[j] == 2.toByte())) { break }
                            buf.add(msdpPacket[j])
                            j++
                        }
                        if (nest == 0) {
                            mgr.processVarVal(varName, String(buf.toByteArray(), Charsets.UTF_8))
                        }
                    }
                    else -> {
                        j++
                    }
                }
            }
        }

        return sbLen
    }

    // -- Handler: MCCP2 --

    private fun processDoMccp2() {
        startMCCP2()
    }

    private fun processDontMccp2() {
        endMCCP2()
    }

    /**
     * Start MCCP2 compression. Sends the start marker uncompressed,
     * then all subsequent write() calls are compressed.
     */
    private fun startMCCP2() {
        if (mccp2 != null) return
        val stream = DeflateStream.create()
        if (stream == null) {
            log("MCCP2: failed to initialize deflate stream")
            return
        }

        // Send the MCCP2 start marker BEFORE enabling compression
        writeRaw(byteArrayOf(TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE))

        mccp2 = stream
    }

    /** End MCCP2 compression. */
    fun endMCCP2() {
        val stream = mccp2 ?: return

        // Flush remaining compressed data
        if (CommFlags.DISCONNECT !in baseCommFlags) {
            val final = stream.finish()
            if (final != null) {
                delegate?.telnetSessionWrite(this, final)
            }
        }

        mccp2 = null
        log("MCCP2: COMPRESSION END")
    }

    // -- Handler: MCCP3 --

    private fun processSbMccp3() {
        endMCCP3()

        val stream = InflateStream.create()
        if (stream == null) {
            log("INFO IAC SB MCCP3 FAILED TO INITIALIZE")
            write(byteArrayOf(TC.IAC, TC.WONT, TO.MCCP3))
            return
        }

        mccp3 = stream
        log("INFO IAC SB MCCP3 INITIALIZED")
    }

    /** End MCCP3 decompression. */
    fun endMCCP3() {
        if (mccp3 == null) return
        log("MCCP3: COMPRESSION END")
        mccp3 = null
    }

    private companion object {
        // ESC[7z — Lock Locked: makes "locked" the persistent default line mode so normal
        // output is never parsed as MXP markup; links opt back in per-span with ESC[1z…ESC[2z.
        val MXP_LOCKED_DEFAULT = byteArrayOf(0x1B, 0x5B, 0x37, 0x7A)

        // The MXP start command: WILL/DO only agrees the option; strict clients
        // stay inert until they receive this subnegotiation.
        val MXP_START = byteArrayOf(TC.IAC, TC.SB, TO.MXP, TC.IAC, TC.SE)
    }
}
