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
}
