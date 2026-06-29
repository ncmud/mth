package mth.core.client

import mth.core.*

private typealias TC = TelnetCommand
private typealias TO = TelnetOption
private typealias TS = TelnetSub

/**
 * A client-side telnet session for MUD clients.
 *
 * Handles the inverse of the server-side negotiation: receives WILL/DO from the
 * server and responds with DO/WILL (or DONT/WONT for unsupported options).
 */
class TelnetClientSession(
    var delegate: TelnetClientDelegate? = null,
    var terminalType: String = "MTH",
    var windowWidth: Int = 80,
    var windowHeight: Int = 24
) {
    // -- Public State --

    /** Whether MCCP2 decompression is active for inbound data. */
    val isMCCP2Active: Boolean get() = mccp2 != null

    /** Whether the server is echoing (client should disable local echo). */
    var serverEcho: Boolean = false
        private set

    /** Whether GMCP has been negotiated. */
    var gmcpEnabled: Boolean = false
        private set

    /** Whether MSDP has been negotiated. */
    var msdpEnabled: Boolean = false
        private set

    /** Whether MSSP has been negotiated. */
    var msspEnabled: Boolean = false
        private set

    /** Whether MXP has been negotiated. */
    var mxpEnabled: Boolean = false
        private set

    // -- Private State --

    /** Buffer for incomplete telnet sequences (packet fragmentation). */
    private var telbuf: MutableList<Byte> = mutableListOf()

    /** MCCP2 inflate stream (decompress server→client data). */
    private var mccp2: InflateStream? = null

    /** Whether we're in the middle of MCCP2 startup (just saw IAC SB MCCP2 IAC SE). */
    private var mccp2Starting: Boolean = false

    /** Set of options the server has offered via WILL that we accepted. */
    private val serverOptions: MutableSet<Byte> = mutableSetOf()

    /** Set of options the server asked us to DO that we accepted. */
    private val clientOptions: MutableSet<Byte> = mutableSetOf()

    /** TTYPE negotiation round counter. */
    private var ttypeRound: Int = 0

    // -- Connection Lifecycle --

    /** Send window size to server. Call after NAWS is negotiated or when window resizes. */
    fun sendWindowSize(width: Int = windowWidth, height: Int = windowHeight) {
        windowWidth = width
        windowHeight = height
        if (TO.NAWS in clientOptions) {
            sendNawsPacket()
        }
    }

    /** Send a GMCP message to the server. */
    fun sendGMCP(module: String, json: String) {
        if (!gmcpEnabled) return
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

    // -- Input Processing --

    /**
     * Process raw input from the server. Strips telnet negotiations,
     * decompresses MCCP2 data, and returns clean display text.
     */
    fun processInput(src: ByteArray): ByteArray {
        var input = src

        // MCCP2: decompress incoming data if active
        val inflater = mccp2
        if (inflater != null) {
            val result = inflater.decompress(input)
            if (result == null) {
                log("MCCP2: Decompression error, disabling MCCP2.")
                mccp2 = null
                return ByteArray(0)
            }
            if (result.finished) {
                log("MCCP2: Compression stream ended.")
                mccp2 = null
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
            when (input[i]) {
                TC.IAC -> {
                    val remaining = input.size - i

                    val (skip, matched) = dispatchTelopt(input, i, remaining)

                    if (!matched && remaining > 1) {
                        val genericSkip = handleGenericTelnet(input, i, remaining, out)
                        if (genericSkip <= remaining) {
                            i += genericSkip
                        } else {
                            telbuf = input.copyOfRange(i, input.size).toMutableList()
                            return out.toByteArray()
                        }
                    } else if (skip <= remaining) {
                        i += skip
                        // After processing IAC SB MCCP2 IAC SE, remaining data is compressed
                        if (mccp2Starting) {
                            mccp2Starting = false
                            if (i < input.size) {
                                // Decompress the rest of this packet
                                val compressed = input.copyOfRange(i, input.size)
                                val decompressed = processInput(compressed)
                                out.addAll(decompressed.toList())
                                return out.toByteArray()
                            }
                        }
                    } else {
                        telbuf = input.copyOfRange(i, input.size).toMutableList()
                        return out.toByteArray()
                    }
                }
                0x0D.toByte() -> { // CR — strip carriage returns (servers send \r\n)
                    i++
                }
                0x07.toByte() -> { // BEL
                    delegate?.onBellReceived()
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
        val handler: (TelnetClientSession, ByteArray, Int, Int) -> Int
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is TeloptPattern) return false
            return pattern.contentEquals(other.pattern)
        }
        override fun hashCode(): Int = pattern.contentHashCode()
    }

    private fun dispatchTelopt(src: ByteArray, i: Int, remaining: Int): Pair<Int, Boolean> {
        for (entry in teloptPatterns) {
            if (remaining < entry.pattern.size) {
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
        return Pair(2, false)
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

    private val teloptPatterns: List<TeloptPattern> by lazy { buildTeloptPatterns() }

    private fun buildTeloptPatterns(): List<TeloptPattern> {
        return listOf(
            // Server offers GMCP
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.GMCP))
                { s, _, _, _ -> s.processWillGmcp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.GMCP))
                { s, src, i, n -> s.processSbGmcp(src, i, n) },

            // Server offers MXP — accept so it may send MXP markup.
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.MXP))
                { s, _, _, _ -> s.processWillMxp(); 3 },

            // Server offers MCCP2
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.MCCP2))
                { s, _, _, _ -> s.processWillMccp2(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE))
                { s, _, _, _ -> s.processSbMccp2(); 5 },

            // Server offers MSDP
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.MSDP))
                { s, _, _, _ -> s.processWillMsdp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MSDP))
                { s, src, i, n -> s.processSbMsdp(src, i, n) },

            // Server offers MSSP
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.MSSP))
                { s, _, _, _ -> s.processWillMssp(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MSSP))
                { s, src, i, n -> s.processSbMssp(src, i, n) },

            // Server offers ECHO
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.ECHO))
                { s, _, _, _ -> s.processWillEcho(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.WONT, TO.ECHO))
                { s, _, _, _ -> s.processWontEcho(); 3 },

            // Server offers EOR
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.EOR))
                { s, _, _, _ -> s.processWillEor(); 3 },

            // Server offers SGA
            TeloptPattern(byteArrayOf(TC.IAC, TC.WILL, TO.SGA))
                { s, _, _, _ -> s.processWillSga(); 3 },

            // Server requests TTYPE
            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.TTYPE))
                { s, _, _, _ -> s.processDoTtype(); 3 },
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE))
                { s, _, _, _ -> s.processSbTtypeSend(); 6 },

            // Server requests NAWS
            TeloptPattern(byteArrayOf(TC.IAC, TC.DO, TO.NAWS))
                { s, _, _, _ -> s.processDoNaws(); 3 },

            // MCCP1 (option 85) uses a non-standard SB terminator: IAC SB 85 WILL SE
            // where SE appears without a preceding IAC. Skip the 5-byte start sequence.
            TeloptPattern(byteArrayOf(TC.IAC, TC.SB, TO.MCCP1, TC.WILL, TC.SE))
                { _, _, _, _ -> 5 },

            // EOR command (prompt marker)
            TeloptPattern(byteArrayOf(TC.IAC, TC.EOR))
                { s, _, _, _ -> s.processEorCommand(); 2 },

            // GA command (prompt marker)
            TeloptPattern(byteArrayOf(TC.IAC, TC.GA))
                { s, _, _, _ -> s.processGaCommand(); 2 },
        )
    }

    private fun handleGenericTelnet(src: ByteArray, i: Int, remaining: Int, out: MutableList<Byte>): Int {
        if (remaining <= 1) return remaining + 1

        return when (src[i + 1]) {
            TC.WILL -> {
                // Unsupported option: reject
                if (remaining < 3) return remaining + 1
                write(byteArrayOf(TC.IAC, TC.DONT, src[i + 2]))
                3
            }
            TC.DO -> {
                // Unsupported option: reject
                if (remaining < 3) return remaining + 1
                write(byteArrayOf(TC.IAC, TC.WONT, src[i + 2]))
                3
            }
            TC.WONT, TC.DONT -> 3
            TC.SB -> skipSB(src, i, remaining)
            TC.IAC -> {
                out.add(TC.IAC)
                2
            }
            else -> {
                if (TelnetCommand.isCommand(src[i + 1])) 2 else 1
            }
        }
    }

    private fun skipSB(src: ByteArray, offset: Int, srclen: Int): Int {
        val end = offset + srclen
        var j = offset + 1
        while (j < end) {
            if (src[j] == TC.SE && j > offset && src[j - 1] == TC.IAC) {
                return j - offset + 1
            }
            j++
        }
        return srclen + 1
    }

    // -- Output --

    private fun write(data: ByteArray) {
        delegate?.write(data)
    }

    private fun log(message: String) {
        delegate?.log(message)
    }

    // -- Handler: GMCP --

    private fun processWillGmcp() {
        gmcpEnabled = true
        serverOptions.add(TO.GMCP)
        write(byteArrayOf(TC.IAC, TC.DO, TO.GMCP))
        delegate?.onGMCPNegotiated()
    }

    private fun processWillMxp() {
        mxpEnabled = true
        serverOptions.add(TO.MXP)
        write(byteArrayOf(TC.IAC, TC.DO, TO.MXP))
    }

    private fun processSbGmcp(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        // Extract payload between IAC SB GMCP and IAC SE
        val payloadStart = offset + 3
        val payloadEnd = offset + sbLen - 2 // before IAC SE
        if (payloadEnd <= payloadStart) return sbLen

        val payload = String(src.copyOfRange(payloadStart, payloadEnd), Charsets.UTF_8)

        // Split into module name and JSON at first space
        val spaceIdx = payload.indexOf(' ')
        if (spaceIdx > 0) {
            val module = payload.substring(0, spaceIdx)
            val json = payload.substring(spaceIdx + 1)
            delegate?.onGMCPReceived(module, json)
        } else {
            // Module with no payload
            delegate?.onGMCPReceived(payload, "")
        }

        return sbLen
    }

    // -- Handler: MCCP2 --

    private fun processWillMccp2() {
        serverOptions.add(TO.MCCP2)
        write(byteArrayOf(TC.IAC, TC.DO, TO.MCCP2))
    }

    private fun processSbMccp2(): Int {
        val stream = InflateStream.create()
        if (stream == null) {
            log("MCCP2: Failed to initialize inflate stream.")
            return 5
        }
        mccp2 = stream
        mccp2Starting = true
        log("MCCP2: Decompression started.")
        return 5
    }

    // -- Handler: MSDP --

    private fun processWillMsdp() {
        msdpEnabled = true
        serverOptions.add(TO.MSDP)
        write(byteArrayOf(TC.IAC, TC.DO, TO.MSDP))
    }

    private fun processSbMsdp(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

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
                        if (src[j] == 3.toByte() || src[j] == 5.toByte()) nest++
                        else if (src[j] == 4.toByte() || src[j] == 6.toByte()) nest--
                        else if (nest == 0 && (src[j] == 1.toByte() || src[j] == 2.toByte())) break
                        buf.add(src[j])
                        j++
                    }
                    val valStr = String(buf.toByteArray(), Charsets.UTF_8)
                    if (nest == 0 && varName.isNotEmpty()) {
                        delegate?.onMSDPVariable(varName, valStr)
                    }
                }
                else -> j++
            }
        }

        return sbLen
    }

    // -- Handler: MSSP --

    private fun processWillMssp() {
        msspEnabled = true
        serverOptions.add(TO.MSSP)
        write(byteArrayOf(TC.IAC, TC.DO, TO.MSSP))
    }

    private fun processSbMssp(src: ByteArray, offset: Int, srclen: Int): Int {
        val sbLen = skipSB(src, offset, srclen)
        if (sbLen > srclen) return srclen + 1

        val data = mutableMapOf<String, String>()
        var varName = ""
        var j = offset + 3
        val end = offset + srclen

        while (j < end && src[j] != TC.SE) {
            when (src[j]) {
                1.toByte() -> { // MSSP_VAR
                    j++
                    val buf = mutableListOf<Byte>()
                    while (j < end && src[j] != 1.toByte() && src[j] != 2.toByte() && src[j] != TC.IAC) {
                        buf.add(src[j])
                        j++
                    }
                    varName = String(buf.toByteArray(), Charsets.UTF_8)
                }
                2.toByte() -> { // MSSP_VAL
                    j++
                    val buf = mutableListOf<Byte>()
                    while (j < end && src[j] != 1.toByte() && src[j] != 2.toByte() && src[j] != TC.IAC) {
                        buf.add(src[j])
                        j++
                    }
                    if (varName.isNotEmpty()) {
                        data[varName] = String(buf.toByteArray(), Charsets.UTF_8)
                    }
                }
                else -> j++
            }
        }

        if (data.isNotEmpty()) {
            delegate?.onMSSPReceived(data)
        }

        return sbLen
    }

    // -- Handler: ECHO --

    private fun processWillEcho() {
        serverOptions.add(TO.ECHO)
        serverEcho = true
        write(byteArrayOf(TC.IAC, TC.DO, TO.ECHO))
        delegate?.onLocalEchoChanged(false)
    }

    private fun processWontEcho() {
        serverOptions.remove(TO.ECHO)
        serverEcho = false
        write(byteArrayOf(TC.IAC, TC.DONT, TO.ECHO))
        delegate?.onLocalEchoChanged(true)
    }

    // -- Handler: EOR --

    private fun processWillEor() {
        serverOptions.add(TO.EOR)
        write(byteArrayOf(TC.IAC, TC.DO, TO.EOR))
    }

    // -- Handler: SGA --

    private fun processWillSga() {
        serverOptions.add(TO.SGA)
        write(byteArrayOf(TC.IAC, TC.DO, TO.SGA))
    }

    // -- Handler: TTYPE --

    private fun processDoTtype() {
        clientOptions.add(TO.TTYPE)
        ttypeRound = 0
        write(byteArrayOf(TC.IAC, TC.WILL, TO.TTYPE))
    }

    private fun processSbTtypeSend() {
        val name = when (ttypeRound) {
            0 -> terminalType
            1 -> "$terminalType-256color"
            else -> "MTTS 137" // ANSI | VT100 | UTF8 | COLORS_256
        }
        ttypeRound++

        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.TTYPE)
        packet.add(TS.ENV_IS)
        packet.addAll(name.toByteArray(Charsets.UTF_8).toList())
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    // -- Handler: NAWS --

    private fun processDoNaws() {
        clientOptions.add(TO.NAWS)
        write(byteArrayOf(TC.IAC, TC.WILL, TO.NAWS))
        sendNawsPacket()
    }

    private fun sendNawsPacket() {
        val colsHi = ((windowWidth shr 8) and 0xFF).toByte()
        val colsLo = (windowWidth and 0xFF).toByte()
        val rowsHi = ((windowHeight shr 8) and 0xFF).toByte()
        val rowsLo = (windowHeight and 0xFF).toByte()

        val packet = mutableListOf<Byte>()
        packet.add(TC.IAC)
        packet.add(TC.SB)
        packet.add(TO.NAWS)
        addNawsByte(packet, colsHi)
        addNawsByte(packet, colsLo)
        addNawsByte(packet, rowsHi)
        addNawsByte(packet, rowsLo)
        packet.add(TC.IAC)
        packet.add(TC.SE)
        write(packet.toByteArray())
    }

    /** Add a NAWS value byte, doubling IAC (0xFF) per RFC 855. */
    private fun addNawsByte(packet: MutableList<Byte>, b: Byte) {
        packet.add(b)
        if (b == TC.IAC) {
            packet.add(b)
        }
    }

    // -- Handler: EOR/GA Commands --

    private fun processEorCommand(): Int {
        delegate?.onPromptReceived()
        return 2
    }

    private fun processGaCommand(): Int {
        delegate?.onPromptReceived()
        return 2
    }
}
