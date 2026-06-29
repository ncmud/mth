package mth.core.client

import mth.core.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertContentEquals

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

private const val ECHO: Byte = 1
private const val SGA: Byte = 3
private const val TTYPE: Byte = 24
private const val EOR_OPT: Byte = 25
private const val NAWS: Byte = 31
private const val MSDP: Byte = 69
private const val MSSP: Byte = 70
private const val MCCP1: Byte = 85
private const val MCCP2: Byte = 86
private const val GMCP: Byte = 0xC9.toByte()

private const val ENV_IS: Byte = 0
private const val ENV_SEND: Byte = 1

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

private class FakeClientDelegate : TelnetClientDelegate {
    val writtenChunks = mutableListOf<ByteArray>()
    val logMessages = mutableListOf<String>()
    val gmcpMessages = mutableListOf<Pair<String, String>>()
    val msdpVariables = mutableListOf<Pair<String, String>>()
    val msspData = mutableListOf<Map<String, String>>()
    var localEchoEnabled: Boolean? = null
    var promptCount = 0
    var bellCount = 0
    var gmcpNegotiatedCount = 0

    val allWrittenBytes: ByteArray get() = writtenChunks.fold(byteArrayOf()) { acc, chunk -> acc + chunk }

    override fun write(data: ByteArray) {
        writtenChunks.add(data.copyOf())
    }
    override fun onLocalEchoChanged(enabled: Boolean) {
        localEchoEnabled = enabled
    }
    override fun onGMCPNegotiated() {
        gmcpNegotiatedCount++
    }
    override fun onGMCPReceived(module: String, json: String) {
        gmcpMessages.add(Pair(module, json))
    }
    override fun onMSDPVariable(name: String, value: String) {
        msdpVariables.add(Pair(name, value))
    }
    override fun onMSSPReceived(data: Map<String, String>) { msspData.add(data) }
    override fun onPromptReceived() {
        promptCount++
    }
    override fun onBellReceived() {
        bellCount++
    }
    override fun log(message: String) {
        logMessages.add(message)
    }
}

private fun makeSession(): Pair<TelnetClientSession, FakeClientDelegate> {
    val d = FakeClientDelegate()
    val s = TelnetClientSession(delegate = d)
    return Pair(s, d)
}

class TelnetClientSessionTest {

    // -- Plain Text --

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

    // -- IAC IAC Escape --

    @Test fun iacIacProducesLiteralFF() {
        val (s, _) = makeSession()
        val out = s.processInput(bytes(0x41, 0xFF, 0xFF, 0x42))
        assertContentEquals(bytes(0x41, 0xFF, 0x42), out)
    }

    // -- GMCP --

    @Test fun serverWillGmcpRespondsDoGmcp() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        assertTrue(s.gmcpEnabled)
        assertContentEquals(byteArrayOf(IAC, DO, GMCP), d.allWrittenBytes)
    }

    @Test fun serverWillMxpRespondsDoMxp() {
        val (s, d) = makeSession()
        assertFalse(s.mxpEnabled)
        s.processInput(bytes(0xFF, 0xFB, 91))
        assertTrue(s.mxpEnabled)
        assertContentEquals(bytes(0xFF, 0xFD, 91), d.allWrittenBytes)
    }

    @Test fun serverSendsGmcpDataParsed() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        d.writtenChunks.clear()

        val payload = textBytes("Char.Vitals {\"hp\":100,\"mana\":50}")
        val packet = byteArrayOf(IAC, SB, GMCP) + payload + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals(1, d.gmcpMessages.size)
        assertEquals("Char.Vitals", d.gmcpMessages[0].first)
        assertEquals("{\"hp\":100,\"mana\":50}", d.gmcpMessages[0].second)
    }

    @Test fun gmcpModuleWithNoPayload() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))

        val packet = byteArrayOf(IAC, SB, GMCP) + textBytes("Core.Ping") + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals(1, d.gmcpMessages.size)
        assertEquals("Core.Ping", d.gmcpMessages[0].first)
        assertEquals("", d.gmcpMessages[0].second)
    }

    @Test fun sendGmcpToServer() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        d.writtenChunks.clear()

        s.sendGMCP("core.hello", "{\"client\":\"MTH\"}")

        val expected = byteArrayOf(IAC, SB, GMCP) +
            textBytes("core.hello {\"client\":\"MTH\"}") +
            byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun sendGmcpWithoutNegotiationDoesNothing() {
        val (s, d) = makeSession()
        s.sendGMCP("core.hello", "{}")
        assertTrue(d.writtenChunks.isEmpty())
    }

    // -- MCCP2 --

    @Test fun serverWillMccp2RespondsDoMccp2() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MCCP2))
        assertContentEquals(byteArrayOf(IAC, DO, MCCP2), d.allWrittenBytes)
    }

    @Test fun serverSbMccp2StartsDecompression() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MCCP2))
        d.writtenChunks.clear()

        // Server sends MCCP2 start marker + compressed data
        val plaintext = textBytes("Hello from server!")
        val deflater = DeflateStream.create()!!
        val compressed = deflater.compress(plaintext)!!

        val packet = byteArrayOf(IAC, SB, MCCP2, IAC, SE) + compressed
        val out = s.processInput(packet)

        assertTrue(s.isMCCP2Active)
        assertContentEquals(plaintext, out)
    }

    @Test fun mccp2DecompressionAcrossMultiplePackets() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MCCP2))
        d.writtenChunks.clear()

        // Start MCCP2
        s.processInput(byteArrayOf(IAC, SB, MCCP2, IAC, SE))
        assertTrue(s.isMCCP2Active)

        // Now send compressed data
        val plaintext = textBytes("Second packet")
        val deflater = DeflateStream.create()!!
        val compressed = deflater.compress(plaintext)!!

        val out = s.processInput(compressed)
        assertContentEquals(plaintext, out)
    }

    // -- ECHO --

    @Test fun serverWillEchoDisablesLocalEcho() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, ECHO))
        assertTrue(s.serverEcho)
        assertEquals(false, d.localEchoEnabled)
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, DO, ECHO)))
    }

    @Test fun serverWontEchoEnablesLocalEcho() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, ECHO))
        d.writtenChunks.clear()

        s.processInput(byteArrayOf(IAC, WONT, ECHO))
        assertFalse(s.serverEcho)
        assertEquals(true, d.localEchoEnabled)
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, DONT, ECHO)))
    }

    // -- TTYPE --

    @Test fun serverDoTtypeRespondsWillTtype() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, TTYPE))
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, WILL, TTYPE)))
    }

    @Test fun serverSbTtypeSendRespondsWithTerminalType() {
        val (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        s.processInput(byteArrayOf(IAC, DO, TTYPE))
        d.writtenChunks.clear()

        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))

        val expected = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("Wamdroid") + byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun ttypeSecondRoundSends256Color() {
        val (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        s.processInput(byteArrayOf(IAC, DO, TTYPE))
        d.writtenChunks.clear()

        // First request
        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))
        d.writtenChunks.clear()

        // Second request
        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))

        val expected = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("Wamdroid-256color") + byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun ttypeThirdRoundSendsMTTS() {
        val (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        s.processInput(byteArrayOf(IAC, DO, TTYPE))
        d.writtenChunks.clear()

        // Three requests
        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))
        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))
        d.writtenChunks.clear()
        s.processInput(byteArrayOf(IAC, SB, TTYPE, ENV_SEND, IAC, SE))

        val expected = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("MTTS 137") + byteArrayOf(IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    // -- NAWS --

    @Test fun serverDoNawsRespondsWillAndSendsSize() {
        val (s, d) = makeSession()
        s.windowWidth = 120
        s.windowHeight = 40
        s.processInput(byteArrayOf(IAC, DO, NAWS))

        val written = d.allWrittenBytes
        assertTrue(written.containsSequence(byteArrayOf(IAC, WILL, NAWS)))
        // Also should contain NAWS subnegotiation: IAC SB NAWS 0 120 0 40 IAC SE
        assertTrue(written.containsSequence(byteArrayOf(IAC, SB, NAWS, 0, 120, 0, 40, IAC, SE)))
    }

    @Test fun sendWindowSizeUpdatesNaws() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, NAWS))
        d.writtenChunks.clear()

        s.sendWindowSize(200, 50)
        val expected = byteArrayOf(IAC, SB, NAWS, 0, 200.toByte(), 0, 50, IAC, SE)
        assertContentEquals(expected, d.allWrittenBytes)
    }

    @Test fun sendWindowSizeBeforeNegotiationDoesNothing() {
        val (s, d) = makeSession()
        s.sendWindowSize(120, 40)
        assertTrue(d.writtenChunks.isEmpty())
    }

    // -- MSDP --

    @Test fun serverWillMsdpRespondsDo() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MSDP))
        assertTrue(s.msdpEnabled)
        assertContentEquals(byteArrayOf(IAC, DO, MSDP), d.allWrittenBytes)
    }

    @Test fun serverSendsMsdpVariableUpdate() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MSDP))
        d.writtenChunks.clear()

        val MV: Byte = 1
        val ML: Byte = 2
        val packet = byteArrayOf(IAC, SB, MSDP, MV) + textBytes("HEALTH") +
            byteArrayOf(ML) + textBytes("100") + byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals(1, d.msdpVariables.size)
        assertEquals("HEALTH", d.msdpVariables[0].first)
        assertEquals("100", d.msdpVariables[0].second)
    }

    // -- EOR / GA (Prompt) --

    @Test fun serverEorTriggersPrompt() {
        val (s, d) = makeSession()
        val out = s.processInput(textBytes("HP: 100> ") + byteArrayOf(IAC, EOR_CMD))
        assertContentEquals(textBytes("HP: 100> "), out)
        assertEquals(1, d.promptCount)
    }

    @Test fun serverGaTriggersPrompt() {
        val (s, d) = makeSession()
        val out = s.processInput(textBytes("HP: 100> ") + byteArrayOf(IAC, GA))
        assertContentEquals(textBytes("HP: 100> "), out)
        assertEquals(1, d.promptCount)
    }

    // -- Packet Fragmentation --

    @Test fun fragmentedIacSequenceReassembles() {
        val (s, d) = makeSession()
        // Split IAC WILL GMCP across two packets
        val out1 = s.processInput(byteArrayOf(0x41, IAC, WILL))
        assertContentEquals(bytes(0x41), out1)

        val out2 = s.processInput(byteArrayOf(GMCP, 0x42))
        assertContentEquals(bytes(0x42), out2)
        assertTrue(s.gmcpEnabled)
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, DO, GMCP)))
    }

    @Test fun fragmentedSubnegotiationReassembles() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        d.writtenChunks.clear()
        d.gmcpMessages.clear()

        // Split GMCP subnegotiation across packets
        val out1 = s.processInput(byteArrayOf(IAC, SB, GMCP) + textBytes("Char.Name"))
        assertTrue(out1.isEmpty())

        val out2 = s.processInput(textBytes(" \"Hero\"") + byteArrayOf(IAC, SE))
        assertTrue(out2.isEmpty())
        assertEquals(1, d.gmcpMessages.size)
        assertEquals("Char.Name", d.gmcpMessages[0].first)
        assertEquals("\"Hero\"", d.gmcpMessages[0].second)
    }

    // -- Unsupported Options --

    @Test fun unsupportedWillGetsDont() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, 99))
        assertContentEquals(byteArrayOf(IAC, DONT, 99), d.allWrittenBytes)
    }

    @Test fun unsupportedDoGetsWont() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, DO, 99))
        assertContentEquals(byteArrayOf(IAC, WONT, 99), d.allWrittenBytes)
    }

    // -- Mixed Input --

    @Test fun mixedTextAndTelnet() {
        val (s, d) = makeSession()
        val input = textBytes("Welcome!") + byteArrayOf(IAC, WILL, ECHO) + textBytes(" Login:")
        val out = s.processInput(input)
        assertContentEquals(textBytes("Welcome! Login:"), out)
        assertTrue(s.serverEcho)
    }

    @Test fun multipleNegotiationsInOnePacket() {
        val (s, d) = makeSession()
        val input = byteArrayOf(IAC, WILL, GMCP, IAC, WILL, ECHO, IAC, WILL, EOR_OPT)
        s.processInput(input)
        assertTrue(s.gmcpEnabled)
        assertTrue(s.serverEcho)

        val written = d.allWrittenBytes
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, GMCP)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, ECHO)))
        assertTrue(written.containsSequence(byteArrayOf(IAC, DO, EOR_OPT)))
    }

    // -- SGA --

    @Test fun serverWillSgaRespondsDo() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, SGA))
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, DO, SGA)))
    }

    // -- CR Stripping --

    @Test fun carriageReturnStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x48, 0x69, 0x0D, 0x0A)) // "Hi\r\n"
        assertContentEquals(byteArrayOf(0x48, 0x69, 0x0A), out) // "Hi\n"
    }

    @Test fun loneCrStripped() {
        val (s, _) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, 0x0D, 0x42)) // "A\rB"
        assertContentEquals(byteArrayOf(0x41, 0x42), out) // "AB"
    }

    // -- BEL --

    @Test fun bellStrippedAndDelegateNotified() {
        val (s, d) = makeSession()
        val out = s.processInput(byteArrayOf(0x41, 0x07, 0x42)) // "A<BEL>B"
        assertContentEquals(byteArrayOf(0x41, 0x42), out) // "AB"
        assertEquals(1, d.bellCount)
    }

    @Test fun multipleBells() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(0x07, 0x07, 0x07))
        assertEquals(3, d.bellCount)
    }

    // -- GMCP Negotiated Callback --

    @Test fun gmcpNegotiatedCallbackFires() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        assertEquals(1, d.gmcpNegotiatedCount)
    }

    @Test fun gmcpNegotiatedCallbackFiresOnlyOnce() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        s.processInput(byteArrayOf(IAC, WILL, GMCP))
        // Second WILL GMCP still fires — the library doesn't deduplicate,
        // but in practice servers only send it once
        assertEquals(2, d.gmcpNegotiatedCount)
    }

    // -- MSSP --

    @Test fun serverWillMsspRespondsDo() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MSSP))
        assertTrue(s.msspEnabled)
        assertContentEquals(byteArrayOf(IAC, DO, MSSP), d.allWrittenBytes)
    }

    @Test fun serverSendsMsspData() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MSSP))
        d.writtenChunks.clear()

        val MV: Byte = 1
        val ML: Byte = 2
        val packet = byteArrayOf(IAC, SB, MSSP, MV) + textBytes("NAME") +
            byteArrayOf(ML) + textBytes("TestMUD") +
            byteArrayOf(MV) + textBytes("PLAYERS") +
            byteArrayOf(ML) + textBytes("42") +
            byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals(1, d.msspData.size)
        assertEquals("TestMUD", d.msspData[0]["NAME"])
        assertEquals("42", d.msspData[0]["PLAYERS"])
    }

    @Test fun msspWithMultipleValues() {
        val (s, d) = makeSession()
        s.processInput(byteArrayOf(IAC, WILL, MSSP))
        d.writtenChunks.clear()

        val MV: Byte = 1
        val ML: Byte = 2
        // MSSP_VAR "GENRE" MSSP_VAL "Fantasy" MSSP_VAL "Adventure" — last value wins
        val packet = byteArrayOf(IAC, SB, MSSP, MV) + textBytes("GENRE") +
            byteArrayOf(ML) + textBytes("Fantasy") +
            byteArrayOf(ML) + textBytes("Adventure") +
            byteArrayOf(IAC, SE)
        s.processInput(packet)

        assertEquals(1, d.msspData.size)
        assertEquals("Adventure", d.msspData[0]["GENRE"])
    }

    // -- MCCP1 non-standard SB terminator --

    @Test fun mccp1StartSequenceSkipped() {
        // MCCP1 uses IAC SB 85 WILL SE (non-standard: SE without preceding IAC).
        // The parser must skip these 5 bytes without poisoning telbuf.
        val (s, _) = makeSession()
        val mccp1Start = byteArrayOf(IAC, SB, MCCP1, WILL, SE)
        val text = textBytes("Hello")
        val out = s.processInput(mccp1Start + text)
        assertContentEquals(text, out, "MCCP1 start marker should be skipped, text should pass through")
    }

    @Test fun mccp1StartSequenceBetweenMsspAndText() {
        // Reproduces the nanvaent bug: decompressed data contains MSSP SB + MCCP1 start,
        // followed by banner text in the next chunk.
        val (s, d) = makeSession()

        // Chunk 1: MSSP subneg + MCCP1 start marker (no IAC SE terminator for MCCP1)
        val MV: Byte = 1; val ML: Byte = 2
        val chunk1 = byteArrayOf(IAC, SB, MSSP, MV) + textBytes("NAME") +
            byteArrayOf(ML) + textBytes("Nanvaent") +
            byteArrayOf(IAC, SE) +
            byteArrayOf(IAC, SB, MCCP1, WILL, SE) // MCCP1 start (non-standard terminator)
        val out1 = s.processInput(chunk1)
        assertTrue(out1.isEmpty(), "Chunk 1 should contain only telnet commands")
        assertEquals(1, d.msspData.size)
        assertEquals("Nanvaent", d.msspData[0]["NAME"])

        // Chunk 2: plain text banner
        val banner = textBytes("Enter your name: ")
        val out2 = s.processInput(banner)
        assertContentEquals(banner, out2, "Banner text should not be swallowed by incomplete MCCP1 SB")
    }

    // -- Nanvaent Replay --

    @Test fun nanvaentNegotiationAndMCCP2() {
        val (s, d) = makeSession()
        s.terminalType = "Wammer"

        // Round 1: DO TTYPE
        s.processInput(bytes(0xFF, 0xFD, 0x18))
        assertTrue(d.allWrittenBytes.containsSequence(byteArrayOf(IAC, WILL, TTYPE)))

        // Round 2: DO NAWS, WILL MCCP2, DO MXP(91), WILL MSSP, WILL 93, DO NEW_ENVIRON
        d.writtenChunks.clear()
        s.processInput(bytes(
            0xFF, 0xFD, 0x1F, 0xFF, 0xFB, 0x56, 0xFF, 0xFD, 0x5B, 0xFF, 0xFB, 0x46, 0xFF, 0xFB, 0x5D, 0xFF,
            0xFD, 0x27
        ))
        val r2 = d.allWrittenBytes
        assertTrue(r2.containsSequence(byteArrayOf(IAC, WILL, NAWS)))
        assertTrue(r2.containsSequence(byteArrayOf(IAC, DO, MCCP2)))
        assertTrue(r2.containsSequence(byteArrayOf(IAC, WONT, 91.toByte())))  // MXP
        assertTrue(r2.containsSequence(byteArrayOf(IAC, DO, MSSP)))
        assertTrue(r2.containsSequence(byteArrayOf(IAC, DONT, 93.toByte()))) // unknown
        assertTrue(r2.containsSequence(byteArrayOf(IAC, WONT, 39)))          // NEW_ENVIRON

        // Round 3: SB TTYPE SEND
        d.writtenChunks.clear()
        s.processInput(bytes(0xFF, 0xFA, 0x18, 0x01, 0xFF, 0xF0))
        val ttypeResponse = byteArrayOf(IAC, SB, TTYPE, ENV_IS) + textBytes("Wammer") + byteArrayOf(IAC, SE)
        assertContentEquals(ttypeResponse, d.allWrittenBytes)

        // Round 4: SB MCCP2 (compression starts)
        d.writtenChunks.clear()
        s.processInput(bytes(0xFF, 0xFA, 0x56, 0xFF, 0xF0))
        assertTrue(s.isMCCP2Active)

        // Round 5: compressed telnet data (MSSP + MCCP1 start)
        val out5 = s.processInput(bytes(
            0x78, 0xDA, 0xFA, 0xFF, 0xCB, 0x0D, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62, 0xF4, 0x73, 0xF4, 0x75,
            0x65, 0xF2, 0x4B, 0xCC, 0x2B, 0x4B, 0x4C, 0xCD, 0x2B, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62,
            0x0C, 0xF0, 0x71, 0x8C, 0x74, 0x0D, 0x0A, 0x66, 0xB2, 0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62,
            0x0C, 0x0D, 0x08, 0xF1, 0x04, 0xCA, 0x18, 0x9A, 0x9B, 0x1B, 0x5A, 0x98, 0x5B, 0x9A, 0x1A, 0x1A,
            0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFA, 0xFF, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFA, 0xFF,
            0x2B, 0xF4, 0xF7, 0x07, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF
        ))
        assertEquals(1, d.msspData.size, "MSSP data should be received from compressed stream")
        assertEquals("Nanvaent", d.msspData[0]["NAME"])
        assertTrue(out5.isEmpty(), "Round 5 should contain only telnet commands")

        // Round 6: compressed banner text
        val out6 = s.processInput(bytes(
            0xB4, 0x53, 0x3D, 0x6F, 0xC3, 0x20, 0x10, 0xDD, 0x2D, 0xF9, 0x3F, 0x9C, 0xB2, 0xA4, 0x1D, 0x12,
            0xF6, 0x48, 0x91, 0xDA, 0xC1, 0x5B, 0x87, 0x48, 0x55, 0x87, 0xAA, 0x54, 0x16, 0x49, 0x88, 0x4D,
            0x6B, 0x43, 0x64, 0x83, 0x2A, 0xFF, 0xFB, 0xDE, 0x61, 0x9C, 0x92, 0xC4, 0xAD, 0xBB, 0xE4, 0x84,
            0x6C, 0xEE, 0xE3, 0x3D, 0xB8, 0x07, 0xA4, 0x09, 0xBC, 0xAD, 0xD7, 0xEB, 0xC5, 0x99, 0x61, 0xE0,
            0x1D, 0xB2, 0x45, 0x2D, 0x54, 0x05, 0x2B, 0xD0, 0x81, 0xED, 0x61, 0x98, 0x2C, 0x4D, 0x53, 0xFC,
            0x82, 0x4A, 0x13, 0x24, 0x9C, 0x32, 0xC6, 0xFD, 0x6F, 0xBA, 0x92, 0x01, 0xF0, 0xEB, 0x68, 0x9E,
            0x4F, 0x22, 0x19, 0xAD, 0xC1, 0xC7, 0xE8, 0xA6, 0xA0, 0xAC, 0x5F, 0xF4, 0x12, 0x8B, 0x3E, 0x9B,
            0x80, 0x7A, 0xE4, 0x08, 0x96, 0xF5, 0xC8, 0x3C, 0x32, 0xEF, 0x84, 0x10, 0x16, 0xE4, 0xAC, 0x77,
            0x08, 0x1A, 0x65, 0x10, 0x78, 0x05, 0xF2, 0x86, 0x74, 0x77, 0x71, 0x62, 0x58, 0x97, 0xE6, 0xBC,
            0x77, 0x42, 0x13, 0xA7, 0x50, 0x0E, 0x43, 0x86, 0xE8, 0x91, 0x2A, 0xA2, 0xBE, 0x0F, 0x8D, 0x9D,
            0x38, 0xB9, 0xEF, 0x77, 0x80, 0x0D, 0x83, 0xE8, 0x4E, 0x21, 0xDA, 0xDE, 0x90, 0xF1, 0x9F, 0x0B,
            0xAE, 0x1F, 0x3E, 0x4E, 0x83, 0xF1, 0xBE, 0xA3, 0xC8, 0x89, 0x42, 0xD4, 0x6A, 0x9F, 0xA1, 0xFD,
            0xB1, 0x4B, 0x9E, 0x71, 0x9D, 0xE3, 0xB3, 0xE1, 0x91, 0xCE, 0xFF, 0xC3, 0x04, 0x54, 0xC0, 0xBC,
            0xB4, 0x12, 0xE6, 0x85, 0x93, 0xAD, 0x9D, 0x83, 0x3A, 0xFC, 0x71, 0xF7, 0xBC, 0x04, 0xCC, 0xDF,
            0xDC, 0xCE, 0x38, 0xF8, 0x70, 0xAD, 0x85, 0x2F, 0xA1, 0x2D, 0x58, 0x13, 0xC4, 0x65, 0x30, 0x02,
            0x22, 0x32, 0xC2, 0x54, 0xC6, 0x7C, 0x82, 0x68, 0x8C, 0xD3, 0xFB, 0xE5, 0xC4, 0x0D, 0xF6, 0xA7,
            0x15, 0x5E, 0x93, 0x95, 0x95, 0x96, 0x16, 0xCE, 0x9E, 0xDF, 0xA4, 0x95, 0xD6, 0x1E, 0x57, 0x8C,
            0xC5, 0x20, 0x76, 0x83, 0xC7, 0xFE, 0x6A, 0x5C, 0x03, 0x8D, 0x2A, 0x4A, 0xDB, 0x42, 0x2D, 0x3A,
            0xD8, 0x4A, 0xD8, 0xAB, 0x76, 0x57, 0x09, 0x55, 0x4B, 0x6C, 0x72, 0x53, 0x49, 0x81, 0xE2, 0xDA,
            0xEE, 0x28, 0x61, 0x56, 0xCA, 0xEA, 0x18, 0x6A, 0x67, 0x20, 0x0E, 0x56, 0x36, 0xA8, 0x48, 0xA1,
            0xF4, 0x32, 0x4D, 0x36, 0x4F, 0xD9, 0xE3, 0x73, 0x06, 0x8E, 0x6A, 0x4B, 0x3C, 0x8C, 0xAD, 0x2B,
            0xE6, 0xB0, 0x33, 0x75, 0x2D, 0xF4, 0x9E, 0xC4, 0xC5, 0x3A, 0xC0, 0x58, 0xEB, 0x65, 0x3F, 0x28,
            0xD4, 0x2F, 0x4D, 0x32, 0x4D, 0x0C, 0x1D, 0x6D, 0x40, 0x8B, 0x5A, 0xAE, 0xE0, 0x1B, 0x00, 0x00,
            0xFF, 0xFF
        ))
        val bannerText = String(out6, Charsets.UTF_8)
        assertTrue(out6.isNotEmpty(), "Banner should not be empty")
        assertTrue(bannerText.contains("Enter your name:"), "Banner should contain login prompt")
        assertTrue(bannerText.contains("nanvaent.org"), "Banner should contain server name")
    }
}
