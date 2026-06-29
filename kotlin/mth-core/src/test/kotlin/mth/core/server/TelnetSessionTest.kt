package mth.core.server

import mth.core.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertNotNull
import kotlin.test.assertContentEquals

// Telnet protocol constants
private const val IAC: Byte = 0xFF.toByte()
private const val DONT: Byte = 0xFE.toByte()
private const val DO: Byte = 0xFD.toByte()
private const val WONT: Byte = 0xFC.toByte()
private const val WILL: Byte = 0xFB.toByte()
private const val SB: Byte = 0xFA.toByte()
private const val GA: Byte = 0xF9.toByte()
private const val SE: Byte = 0xF0.toByte()
private const val EOR_CMD: Byte = 0xEF.toByte()
private const val NOP: Byte = 0xF1.toByte()

// Telnet options
private const val ECHO: Byte = 1
private const val SGA: Byte = 3
private const val TTYPE: Byte = 24
private const val EOR_OPT: Byte = 25
private const val NAWS: Byte = 31
private const val NEW_ENVIRON: Byte = 39
private const val CHARSET: Byte = 42
private const val MSDP: Byte = 69
private const val MSSP: Byte = 70
private const val MCCP2: Byte = 86
private const val MCCP3: Byte = 87
private const val GMCP: Byte = 0xC9.toByte()

// Sub-negotiation constants
private const val ENV_IS: Byte = 0
private const val ENV_SEND: Byte = 1
private const val ENV_VAR: Byte = 0
private const val ENV_VAL: Byte = 1
private const val ENV_USR: Byte = 3
private const val CHARSET_REQUEST: Byte = 1
private const val CHARSET_ACCEPTED: Byte = 2
private const val CHARSET_REJECTED: Byte = 3
private const val MSSP_VAR: Byte = 1
private const val MSSP_VAL: Byte = 2

private class FakeDelegate : TelnetSessionDelegate {
    val writtenChunks = mutableListOf<ByteArray>()
    val logMessages = mutableListOf<String>()
    var msspPairs: List<Pair<String, String>> = emptyList()

    val allWrittenBytes: ByteArray get() = writtenChunks.fold(byteArrayOf()) { acc, chunk -> acc + chunk }

    override fun telnetSessionWrite(session: TelnetSession, data: ByteArray) {
        writtenChunks.add(data.copyOf())
    }
    override fun telnetSessionLog(session: TelnetSession, message: String) {
        logMessages.add(message)
    }
    override fun telnetSessionMSSPData(session: TelnetSession): List<Pair<String, String>> = msspPairs
}

private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

private fun textBytes(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

private fun ByteArray.containsSequence(seq: ByteArray): Boolean {
    if (seq.isEmpty()) return true
    if (size < seq.size) return false
    for (i in 0..(size - seq.size)) {
        if (this.sliceArray(i until i + seq.size).contentEquals(seq)) return true
    }
    return false
}

private fun makeSession(): Pair<TelnetSession, FakeDelegate> {
    val d = FakeDelegate()
    val s = TelnetSession(delegate = d)
    return Pair(s, d)
}

class TelnetSessionTest {

    // -- Plain Text Passthrough --

    @Test fun plainTextPassthrough() {
        val (s, _) = makeSession()
        val input = textBytes("Hello, World!")
        val out = s.processInput(input)
        assertContentEquals(input, out)
    }

    @Test fun emptyInput() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf())
        assertTrue(out.isEmpty())
    }

    // -- MXP --

    @Test fun announcesWillMxp() {
        val (s, d) = makeSession()
        s.announceSupport()
        assertTrue(d.allWrittenBytes.containsSequence(bytes(0xFF, 0xFB, 91)))
    }

    @Test fun doMxpEnablesAndLocksDefault() {
        val (s, d) = makeSession()
        assertFalse(s.mxpEnabled)
        s.processInput(bytes(0xFF, 0xFD, 91))
        assertTrue(s.mxpEnabled)
        assertTrue(d.allWrittenBytes.containsSequence(bytes(0x1B, 0x5B, 0x37, 0x7A)))
    }

    @Test fun dontMxpDisables() {
        val (s, _) = makeSession()
        s.processInput(bytes(0xFF, 0xFD, 91))
        assertTrue(s.mxpEnabled)
        s.processInput(bytes(0xFF, 0xFE, 91))
        assertFalse(s.mxpEnabled)
    }

    // -- CR/NUL Handling --

    @Test fun crNulConvertsToNewline() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x48, 0x0D, 0x00, 0x49))
        assertContentEquals(bytes(0x48, 0x0A, 0x49), out)
    }

    @Test fun crLfSkipsCrKeepsLf() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x48, 0x0D, 0x0A, 0x49))
        assertContentEquals(bytes(0x48, 0x0A, 0x49), out)
    }

    @Test fun standaloneNulStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x48, 0x00, 0x49))
        assertContentEquals(bytes(0x48, 0x49), out)
    }

    @Test fun standaloneCrStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x48, 0x0D))
        assertContentEquals(bytes(0x48), out)
    }

    // -- IAC IAC Escape --

    @Test fun iacIacProducesLiteralFF() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x41, 0xFF, 0xFF, 0x42))
        assertContentEquals(bytes(0x41, 0xFF, 0x42), out)
    }

    // -- WILL/WONT/DO/DONT Stripping --

    @Test fun willIsStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, WILL, SGA, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    @Test fun wontIsStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, WONT, SGA, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    @Test fun doIsStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, DO, SGA, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    @Test fun dontIsStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, DONT, SGA, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    // -- Subnegotiation Stripping --

    @Test fun unknownSubnegotiationStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, SB, 99, 1, 2, 3, IAC, SE, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    // -- Packet Fragmentation --

    @Test fun fragmentedIACReassembles() {
        val (s, _) = makeSession()
        val out1 = s.processInput(byteArrayOf(0x41, IAC))
        assertContentEquals(bytes(0x41), out1)

        val out2 = s.processInput(byteArrayOf(IAC, 0x42))
        assertContentEquals(bytes(0xFF, 0x42), out2)
    }

    @Test fun fragmentedWillReassembles() {
        val (s, _) = makeSession()
        val out1 = s.processInput(byteArrayOf(0x41, IAC, WILL))
        assertContentEquals(bytes(0x41), out1)

        val out2 = s.processInput(byteArrayOf(SGA, 0x42))
        assertContentEquals(bytes(0x42), out2)
    }

    @Test fun fragmentedSubnegotiationReassembles() {
        val (s, _) = makeSession()
        val out1 = s.processInput(byteArrayOf(0x41, IAC, SB, NAWS, 0, 80))
        assertContentEquals(bytes(0x41), out1)

        val out2 = s.processInput(byteArrayOf(0, 24, IAC, SE, 0x42))
        assertContentEquals(bytes(0x42), out2)
        assertEquals(80, s.windowSize.first)
        assertEquals(24, s.windowSize.second)
    }

    // -- Two-byte Commands --

    @Test fun gaCmdStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, GA, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    @Test fun nopCmdStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, IAC, NOP, 0x42))
        assertContentEquals(bytes(0x41, 0x42), out)
    }

    // -- announceSupport / unannounceSupport --

    @Test fun announceSupportSendsExpectedOptions() {
        val (s, d) = makeSession()
        s.announceSupport()

        val written = d.allWrittenBytes
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, CHARSET)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, TTYPE)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, NAWS)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, NEW_ENVIRON)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, MSDP)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, MSSP)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, GMCP)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, MCCP2)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, MCCP3)))
    }

    @Test fun unannounceSupportSendsWontDont() {
        val (s, d) = makeSession()
        s.unannounceSupport()

        val written = d.allWrittenBytes
        assertTrue(written.containsSequence(byteArrayOf(IAC, WONT, CHARSET)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DONT, TTYPE)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DONT, NAWS)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WONT, MSDP)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, WONT, GMCP)))
    }

    // -- Echo On/Off --

    @Test fun sendEchoOffSetsPasswordAndSendsWillEcho() {
        val (s, d) = makeSession()
        s.sendEchoOff()
        assertTrue(CommFlags.PASSWORD in s.commFlags)
        assertContentEquals(byteArrayOf(IAC, WILL, ECHO), d.allWrittenBytes)
    }

    @Test fun sendEchoOnClearsPasswordAndSendsWontEcho() {
        val (s, d) = makeSession()
        s.sendEchoOff()
        d.writtenChunks.clear()
        s.sendEchoOn()
        assertFalse(CommFlags.PASSWORD in s.commFlags)
        assertContentEquals(byteArrayOf(IAC, WONT, ECHO), d.allWrittenBytes)
    }

    // -- Send EOR --

    @Test fun sendEOROnlyWhenEORNegotiated() {
        val (s, d) = makeSession()
        s.sendEOR()
        assertTrue(d.allWrittenBytes.isEmpty())

        s.processInput(byteArrayOf(IAC, DO, EOR_OPT))
        d.writtenChunks.clear()
        s.sendEOR()
        assertContentEquals(byteArrayOf(IAC, EOR_CMD), d.allWrittenBytes)
    }

    // -- DO EOR --

    @Test fun doEorSetsFlag() {
        val (s, _) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, EOR_OPT))
        assertTrue(CommFlags.EOR in s.commFlags)
    }

    // -- Terminal Type --

    @Test fun willTtypeSendsThreeRequestsThenDont() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, TTYPE))

        val request = byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE)

        assertEquals(4, d.writtenChunks.size)
        assertContentEquals(request, d.writtenChunks[0])
        assertContentEquals(request, d.writtenChunks[1])
        assertContentEquals(request, d.writtenChunks[2])
        assertContentEquals(byteArrayOf(IAC, DONT, TTYPE), d.writtenChunks[3])
    }

    @Test fun willTtypeIgnoredIfTerminalAlreadySet() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, TTYPE))
        val firstTtype = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("xterm") + byteArrayOf(IAC, SE)
        s.processInput(firstTtype)
        d.writtenChunks.clear()

        s.processInput(byteArrayOf(IAC, WILL, TTYPE))
        assertTrue(d.writtenChunks.isEmpty())
    }

    @Test fun sbTtypeIsSetsTerminalType() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("xterm-256color") + byteArrayOf(IAC, SE)
        s.processInput(packet)
        assertEquals("xterm-256color", s.terminalType)
    }

    @Test fun sbTtypeIsSecondResponseDetects256Color() {
        val (s, _) = makeSession()
        val first = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("MUDLET") + byteArrayOf(IAC, SE)
        s.processInput(first)
        assertEquals("MUDLET", s.terminalType)

        val second = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("MUDLET-256COLOR") + byteArrayOf(IAC, SE)
        s.processInput(second)
        assertTrue(CommFlags.COLORS_256 in s.commFlags)
    }

    @Test fun sbTtypeIsMTTSDetection() {
        val (s, _) = makeSession()
        val first = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("MUDLET") + byteArrayOf(IAC, SE)
        s.processInput(first)

        val mtts = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("MTTS 15") + byteArrayOf(IAC, SE)
        s.processInput(mtts)

        assertTrue(MTTSFlags.ANSI in s.mttsFlags)
        assertTrue(MTTSFlags.VT100 in s.mttsFlags)
        assertTrue(MTTSFlags.UTF8 in s.mttsFlags)
        assertTrue(MTTSFlags.COLORS_256 in s.mttsFlags)
        assertTrue(CommFlags.COLORS_256 in s.commFlags)
        assertTrue(CommFlags.UTF8 in s.commFlags)
    }

    @Test fun sbTtypeIsXtermSets256Color() {
        val (s, _) = makeSession()
        val first = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("PUTTY") + byteArrayOf(IAC, SE)
        s.processInput(first)

        val second = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("XTERM") + byteArrayOf(IAC, SE)
        s.processInput(second)
        assertTrue(CommFlags.COLORS_256 in s.commFlags)
    }

    // -- NAWS --

    @Test fun nawsSetsWindowSize() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE)
        s.processInput(packet)
        assertEquals(80, s.windowSize.first)
        assertEquals(24, s.windowSize.second)
    }

    @Test fun nawsLargeWindowSize() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, NAWS, 1, 0x2C, 0, 0x64, IAC, SE)
        s.processInput(packet)
        assertEquals(300, s.windowSize.first)
        assertEquals(100, s.windowSize.second)
    }

    @Test fun nawsWithIACStuffing() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, NAWS, IAC, IAC, 0, 0, 24, IAC, SE)
        s.processInput(packet)
        assertEquals(65280, s.windowSize.first)
        assertEquals(24, s.windowSize.second)
    }

    // -- NEW-ENVIRON --

    @Test fun willNewEnvironSendsRequest() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, NEW_ENVIRON))

        val expected = byteArrayOf(IAC, SB, NEW_ENVIRON, ENV_SEND, ENV_VAR) +
            textBytes("SYSTEMTYPE") + byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun sbNewEnvironWin32Detection() {
        val (s, _) = makeSession()
        val ttype = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("ANSI") + byteArrayOf(IAC, SE)
        s.processInput(ttype)
        assertEquals("ANSI", s.terminalType)

        val packet = byteArrayOf(IAC, SB, NEW_ENVIRON, ENV_IS, ENV_VAR) +
            textBytes("SYSTEMTYPE") + byteArrayOf(ENV_VAL) + textBytes("WIN32") + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals("WINDOWS TELNET", s.terminalType)
        assertTrue(CommFlags.REMOTE_ECHO in s.commFlags)
    }

    @Test fun sbNewEnvironIPAddress() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, NEW_ENVIRON, ENV_IS, ENV_VAR) +
            textBytes("IPADDRESS") + byteArrayOf(ENV_VAL) + textBytes("192.168.1.100") + byteArrayOf(IAC, SE)
        s.processInput(packet)
        assertEquals("192.168.1.100", s.proxy)
    }

    // -- CHARSET --

    @Test fun doCharsetSendsRequest() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, CHARSET))

        val expected = byteArrayOf(IAC, SB, CHARSET, CHARSET_REQUEST, 0x20) +
            textBytes("UTF-8") + byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun sbCharsetAcceptedSetsUtf8() {
        val (s, _) = makeSession()
        val packet = byteArrayOf(IAC, SB, CHARSET, CHARSET_ACCEPTED, ';'.code.toByte()) +
            textBytes("UTF-8") + byteArrayOf(IAC, SE)
        s.processInput(packet)
        assertTrue(CommFlags.UTF8 in s.commFlags)
    }

    @Test fun sbCharsetRejectedClearsUtf8() {
        val (s, _) = makeSession()
        val accept = byteArrayOf(IAC, SB, CHARSET, CHARSET_ACCEPTED, ';'.code.toByte()) +
            textBytes("UTF-8") + byteArrayOf(IAC, SE)
        s.processInput(accept)
        assertTrue(CommFlags.UTF8 in s.commFlags)

        val reject = byteArrayOf(IAC, SB, CHARSET, CHARSET_REJECTED, ';'.code.toByte()) +
            textBytes("UTF-8") + byteArrayOf(IAC, SE)
        s.processInput(reject)
        assertFalse(CommFlags.UTF8 in s.commFlags)
    }

    // -- MSSP --

    @Test fun doMsspSendsData() {
        val (s, d) = makeSession()
        d.msspPairs = listOf(
            Pair("NAME", "TestMUD"),
            Pair("PLAYERS", "42"),
        )
        s.processInput(byteArrayOf(IAC, DO, MSSP))

        val written = d.allWrittenBytes
        assertTrue(written.sliceArray(0 until 3).contentEquals(byteArrayOf(IAC, SB, MSSP)))
        assertTrue(written.sliceArray(written.size - 2 until written.size).contentEquals(byteArrayOf(IAC, SE)))
        assertTrue(written.containsSequence(
            byteArrayOf(MSSP_VAR) + textBytes("NAME") + byteArrayOf(MSSP_VAL) + textBytes("TestMUD")
        ))
        assertTrue(written.containsSequence(
            byteArrayOf(MSSP_VAR) + textBytes("PLAYERS") + byteArrayOf(MSSP_VAL) + textBytes("42")
        ))
    }

    // -- MSDP --

    @Test fun doMsdpInitializesManager() {
        val (s, d) = makeSession()
        assertNull(s.msdpManager)
        s.processInput(byteArrayOf(IAC, DO, MSDP))
        assertNotNull(s.msdpManager)
        assertTrue(d.logMessages.contains("INFO MSDP INITIALIZED"))
    }

    @Test fun doMsdpIdempotent() {
        val (s, _) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MSDP))
        val mgr1 = s.msdpManager
        s.processInput(byteArrayOf(IAC, DO, MSDP))
        assertTrue(s.msdpManager === mgr1)
    }

    @Test fun sbMsdpProcessesCommand() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MSDP))
        d.writtenChunks.clear()

        val MV: Byte = 1
        val ML: Byte = 2
        val packet = byteArrayOf(IAC, SB, MSDP, MV) +
            textBytes("LIST") + byteArrayOf(ML) + textBytes("COMMANDS") + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertTrue(d.writtenChunks.isNotEmpty())
    }

    // -- GMCP --

    @Test fun doGmcpInitializesMSDPOverGmcp() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, GMCP))
        assertNotNull(s.msdpManager)
        assertTrue(CommFlags.GMCP in s.commFlags)
        assertTrue(d.logMessages.contains("INFO MSDP OVER GMCP INITIALIZED"))
    }

    @Test fun doGmcpIdempotent() {
        val (s, _) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, GMCP))
        val mgr1 = s.msdpManager
        s.processInput(byteArrayOf(IAC, DO, GMCP))
        assertTrue(s.msdpManager === mgr1)
    }

    @Test fun sbGmcpProcessesJsonCommand() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, GMCP))
        d.writtenChunks.clear()

        val json = textBytes("MSDP {\"LIST\":\"COMMANDS\"}")
        val packet = byteArrayOf(IAC, SB, GMCP) + json + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertTrue(d.writtenChunks.isNotEmpty())
    }

    // -- MCCP2 (Output Compression) --

    @Test fun doMccp2StartsCompression() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        assertTrue(s.isMCCP2Active)

        assertContentEquals(byteArrayOf(IAC, SB, MCCP2, IAC, SE), d.writtenChunks[0])
    }

    @Test fun mccp2CompressesOutput() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        d.writtenChunks.clear()

        s.sendEchoOff()

        assertTrue(d.writtenChunks.isNotEmpty())
        val compressed = d.allWrittenBytes
        assertFalse(compressed.contentEquals(byteArrayOf(IAC, WILL, ECHO)))
        assertTrue(compressed.isNotEmpty())
    }

    @Test fun mccp2RoundTrip() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        d.writtenChunks.clear()

        s.sendEchoOff()
        val compressedEcho = d.allWrittenBytes
        d.writtenChunks.clear()

        s.endMCCP2()
        assertFalse(s.isMCCP2Active)
        val finalBytes = d.allWrittenBytes

        val allCompressed = compressedEcho + finalBytes
        assertTrue(allCompressed.isNotEmpty())
        assertTrue(d.logMessages.contains("MCCP2: COMPRESSION END"))
    }

    @Test fun dontMccp2EndsCompression() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        assertTrue(s.isMCCP2Active)
        s.processInput(byteArrayOf(IAC, DONT, MCCP2))
        assertFalse(s.isMCCP2Active)
        assertTrue(d.logMessages.contains("MCCP2: COMPRESSION END"))
    }

    @Test fun mccp2IdempotentStart() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        val chunks1 = d.writtenChunks.size
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        assertEquals(chunks1, d.writtenChunks.size)
    }

    // -- sendOutput --

    @Test fun sendOutputPassthroughWithoutMCCP2() {
        val (s, d) = makeSession()
        val data = textBytes("Hello, World!\r\n")
        s.sendOutput(data)
        assertContentEquals(data, d.allWrittenBytes)
    }

    @Test fun sendOutputCompressesWithMCCP2() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        d.writtenChunks.clear()

        val data = textBytes("Hello, World!\r\n")
        s.sendOutput(data)

        assertTrue(d.writtenChunks.isNotEmpty())
        val compressed = d.allWrittenBytes
        assertFalse(compressed.contentEquals(data))
        assertTrue(compressed.isNotEmpty())
    }

    // -- MCCP3 (Input Decompression) --

    @Test fun sbMccp3InitializesInflate() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, SB, MCCP3, IAC, SE))
        assertTrue(s.isMCCP3Active)
        assertTrue(d.logMessages.contains("INFO IAC SB MCCP3 INITIALIZED"))
    }

    @Test fun mccp3DecompressesInput() {
        val (s, _) = makeSession()
        s.processInput(byteArrayOf(IAC, SB, MCCP3, IAC, SE))
        assertTrue(s.isMCCP3Active)

        val plaintext = textBytes("Hello") + byteArrayOf(0x0D, 0x00)

        val deflater = DeflateStream.create()
        assertNotNull(deflater)
        val compressed = deflater.compress(plaintext)
        assertNotNull(compressed)

        val out = s.processInput(compressed)
        assertContentEquals(textBytes("Hello\n"), out)
    }

    @Test fun endMccp3DisablesDecompression() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, SB, MCCP3, IAC, SE))
        assertTrue(s.isMCCP3Active)
        s.endMCCP3()
        assertFalse(s.isMCCP3Active)
        assertTrue(d.logMessages.contains("MCCP3: COMPRESSION END"))
    }

    @Test fun unannounceSupportEndsMCCP() {
        val (s, _) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, MCCP2))
        assertTrue(s.isMCCP2Active)
        s.processInput(byteArrayOf(IAC, SB, MCCP3, IAC, SE))
        assertTrue(s.isMCCP3Active)

        s.unannounceSupport()
        assertFalse(s.isMCCP2Active)
        assertFalse(s.isMCCP3Active)
    }

    // -- Mixed Input --

    @Test fun mixedTextAndTelnet() {
        val (s, _) = makeSession()
        val input = textBytes("Hi") + byteArrayOf(IAC, DO, EOR_OPT) + textBytes("Bye") + byteArrayOf(0x0D, 0x00)
        val out = s.processInput(input)
        assertContentEquals(textBytes("HiBye\n"), out)
        assertTrue(CommFlags.EOR in s.commFlags)
    }

    @Test fun multipleNegotiationsInOnePacket() {
        val (s, _) = makeSession()
        val input = byteArrayOf(IAC, DO, EOR_OPT,
            IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE)
        val out = s.processInput(input)
        assertTrue(out.isEmpty())
        assertTrue(CommFlags.EOR in s.commFlags)
        assertEquals(80, s.windowSize.first)
        assertEquals(24, s.windowSize.second)
    }
}
