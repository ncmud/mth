package mth.core

import mth.core.client.TelnetClientSession
import mth.core.client.TelnetClientDelegate
import mth.core.server.TelnetSession
import mth.core.server.TelnetSessionDelegate
import kotlin.test.*

class MNESTest {
    private class ServerOutput : TelnetSessionDelegate {
        val chunks = mutableListOf<ByteArray>()
        val changes = mutableListOf<MNESEnvironment>()
        val bytes get() = chunks.flatMap { it.toList() }.toByteArray()
        override fun telnetSessionWrite(session: TelnetSession, data: ByteArray) { chunks.add(data) }
        override fun telnetSessionEnvironmentChanged(session: TelnetSession, environment: MNESEnvironment) { changes.add(environment) }
    }
    private class ClientOutput : TelnetClientDelegate {
        val chunks = mutableListOf<ByteArray>()
        val bytes get() = chunks.flatMap { it.toList() }.toByteArray()
        override fun write(data: ByteArray) { chunks.add(data) }
        override fun onLocalEchoChanged(enabled: Boolean) {}
        override fun onGMCPReceived(module: String, json: String) {}
        override fun onMSDPVariable(name: String, value: String) {}
        override fun onPromptReceived() {}
    }

    @Test fun clientServerExchangeAndUpdates() {
        for (address in listOf("192.0.2.42", "2001:db8::42", "::1", "::", "::ffff:192.0.2.42")) {
            val serverOutput = ServerOutput()
            val server = TelnetSession(delegate = serverOutput)
            val clientOutput = ClientOutput()
            val client = TelnetClientSession(delegate = clientOutput, terminalType = "XTERM",
                clientName = "Web gateway", clientVersion = "1.2", charset = "UTF-8", ipAddress = address)
            client.processInput(byteArrayOf(-1, -3, 39))
            server.processInput(clientOutput.bytes)
            clientOutput.chunks.clear()
            client.processInput(serverOutput.bytes)
            for (byte in clientOutput.bytes) assertTrue(server.processInput(byteArrayOf(byte)).isEmpty())
            assertEquals(address, server.proxy)
            assertEquals("Web gateway", server.environment.clientName)
            assertEquals("1.2", server.environment.clientVersion)
            assertEquals("XTERM", server.terminalType)
            assertTrue(CommFlags.UTF8 in server.commFlags)
            assertTrue(MTTSFlags.MNES in server.mttsFlags)
            clientOutput.chunks.clear()
            client.ipAddress = "198.51.100.7"
            client.charset = "ASCII"
            client.mttsFlags = 0
            server.processInput(clientOutput.bytes)
            assertEquals("198.51.100.7", server.proxy)
            assertFalse(CommFlags.UTF8 in server.commFlags)
            assertFalse(CommFlags.COLORS_256 in server.commFlags)
        }
    }

    @Test fun gatewayThatOnlyAnswersBareSendReportsAnAddress() {
        val output = ServerOutput()
        val server = TelnetSession(delegate = output)
        server.processInput(byteArrayOf(-1, -5, 39))
        for (request in output.chunks) {
            if (request.contentEquals(byteArrayOf(-1, -6, 39, 1, -1, -16))) {
                val response = byteArrayOf(-1, -6, 39, 0, 0) + "IPADDRESS".toByteArray() +
                    byteArrayOf(1) + "2001:db8::42".toByteArray() + byteArrayOf(-1, -16)
                server.processInput(response)
            }
        }
        assertEquals("2001:db8::42", server.environment.ipAddress)
    }

    @Test fun variableNamesRemainCaseSensitive() {
        val entries = listOf(NewEnviron.Entry("Client_Name", "Mixed"), NewEnviron.Entry("CLIENT_NAME", "Upper"))
        assertEquals(entries, NewEnviron.decode(NewEnviron.packet(0, entries))?.entries)
        val output = ClientOutput()
        val client = TelnetClientSession(delegate = output, clientName = "Example")
        client.processInput(byteArrayOf(-1, -3, 39))
        output.chunks.clear()
        client.processInput(NewEnviron.packet(1, listOf(NewEnviron.Entry("client_name"), NewEnviron.Entry("CLIENT_NAME"))))
        assertEquals(listOf(NewEnviron.Entry("client_name"), NewEnviron.Entry("CLIENT_NAME", "Example")),
            NewEnviron.decode(output.bytes)?.entries)
    }

    @Test fun userVariablesRetainTheirTypeInRepliesAndUpdates() {
        val output = ClientOutput()
        val client = TelnetClientSession(delegate = output, ipAddress = "::1")
        client.processInput(byteArrayOf(-1, -3, 39))
        output.chunks.clear()
        client.processInput(NewEnviron.packet(1, listOf(NewEnviron.Entry("IPADDRESS", userDefined = true))))
        assertEquals(listOf(NewEnviron.Entry("IPADDRESS", "::1", true)), NewEnviron.decode(output.bytes)?.entries)
        output.chunks.clear()
        client.ipAddress = "::2"
        assertEquals(listOf(NewEnviron.Entry("IPADDRESS", "::2", true)), NewEnviron.decode(output.bytes)?.entries)
    }

    @Test fun zeroAndUndefinedCapabilities() {
        val server = TelnetSession(restoringCommFlags = CommFlags.UTF8, mttsFlags = MTTSFlags.UTF8,
            terminalType = "TTYPE-CLIENT", windowSize = 80 to 24, proxy = "")
        server.processInput(byteArrayOf(-1, -5, 39))
        server.processInput(NewEnviron.packet(0, listOf(NewEnviron.Entry("MTTS", "0"))))
        assertTrue(server.hasMTTS)
        assertEquals(0, server.mttsFlags.rawValue)
        assertFalse(CommFlags.UTF8 in server.commFlags)
        server.processInput(NewEnviron.packet(2, listOf(NewEnviron.Entry("MTTS"))))
        assertTrue(CommFlags.UTF8 in server.commFlags)
    }

    @Test fun validationAndMalformedFrames() {
        val server = TelnetSession()
        server.processInput(byteArrayOf(-1, -5, 39))
        server.processInput(NewEnviron.packet(0, listOf(NewEnviron.Entry("IPADDRESS", "192.0.2.1"))))
        for (address in listOf("999.0.0.1", "192.0.2", "localhost", "1.2.3.4:80", "2001:::1", "1::2::3", "::ffff:999.1.1.1", "[::1]", "fe80::1%en0", "01.2.3.4")) {
            server.processInput(NewEnviron.packet(2, listOf(NewEnviron.Entry("IPADDRESS", address))))
            assertEquals("192.0.2.1", server.proxy)
        }
        for (value in listOf("-1", "999999999999999999999999", "abc")) {
            server.processInput(NewEnviron.packet(0, listOf(NewEnviron.Entry("MTTS", value))))
            assertFalse(server.hasMTTS)
        }
        server.processInput(NewEnviron.packet(0, listOf(NewEnviron.Entry("CLIENT_NAME", "bad\u001B[2J"))))
        assertNull(server.environment.clientName)
        val bad = byteArrayOf(-1, -6, 39, 0, 1, 65, -1, -16)
        assertContentEquals("look\n".toByteArray(), server.processInput(bad + "look\n".toByteArray()))
        val escaped = NewEnviron.Entry("EXAMPLE", "a\u0000b\u0001c\u0002d\u0003")
        assertEquals(listOf(escaped), NewEnviron.decode(NewEnviron.packet(0, listOf(escaped)))?.entries)
        assertNull(NewEnviron.frameLength(byteArrayOf(-1, -6, 39, 0, 0, 65, 1, -1, -1, -16), 0))
    }

    @Test fun clientRequestsSubscriptionsAndReset() {
        val output = ClientOutput()
        val client = TelnetClientSession(delegate = output, clientVersion = "1", ipAddress = "::1")
        client.processInput(byteArrayOf(-1, -3, 39))
        for (entries in listOf(emptyList(), listOf(NewEnviron.Entry("")))) {
            output.chunks.clear()
            client.processInput(NewEnviron.packet(1, entries))
            assertEquals(MNESEnvironment.variableNames, NewEnviron.decode(output.bytes)?.entries?.map { it.name })
        }
        client.processInput(byteArrayOf(-1, -2, 39))
        client.processInput(byteArrayOf(-1, -3, 39))
        output.chunks.clear()
        client.processInput(NewEnviron.packet(1, listOf(NewEnviron.Entry("IPADDRESS"), NewEnviron.Entry("UNKNOWN"))))
        assertEquals(listOf(NewEnviron.Entry("IPADDRESS", "::1"), NewEnviron.Entry("UNKNOWN")), NewEnviron.decode(output.bytes)?.entries)
        output.chunks.clear()
        client.clientVersion = "2"
        assertTrue(output.bytes.isEmpty())
        client.ipAddress = "::2"
        assertEquals(2.toByte(), NewEnviron.decode(output.bytes)?.command)
        output.chunks.clear()
        client.processInput(byteArrayOf(-1, -2, 39))
        assertContentEquals(byteArrayOf(-1, -4, 39), output.bytes)
        output.chunks.clear()
        client.ipAddress = "::3"
        assertTrue(output.bytes.isEmpty())
    }

    @Test fun serverNegotiationAndNotifications() {
        val output = ServerOutput()
        val server = TelnetSession(delegate = output)
        val packet = NewEnviron.packet(0, listOf(NewEnviron.Entry("IPADDRESS", "::1")))
        server.processInput(packet)
        assertEquals("", server.proxy)
        server.processInput(byteArrayOf(-1, -5, 39))
        server.processInput(packet)
        output.chunks.clear()
        server.processInput(byteArrayOf(-1, -5, 39))
        assertTrue(output.bytes.isEmpty())
        server.processInput(byteArrayOf(-1, -4, 39))
        assertEquals(MNESEnvironment(), server.environment)
        assertFalse(server.newEnvironEnabled)
        assertEquals(listOf("::1", null), output.changes.map { it.ipAddress })
    }

    @Test fun oversizedFragmentsAreDiscardedUntilTerminator() {
        val server = TelnetSession()
        server.processInput(byteArrayOf(-1, -5, 39))
        assertTrue(server.processInput(byteArrayOf(-1, -6, 39, 0, 0) + ByteArray(9000) { 65 } + byteArrayOf(-1)).isEmpty())
        assertContentEquals("look\n".toByteArray(), server.processInput(byteArrayOf(-16) + "look\n".toByteArray()))
        assertEquals(MNESEnvironment(), server.environment)
        val client = TelnetClientSession()
        assertTrue(client.processInput(byteArrayOf(-1, -6, 39, 1, 0) + ByteArray(9000) { 65 }).isEmpty())
        assertContentEquals("hello".toByteArray(), client.processInput(byteArrayOf(-1, -16) + "hello".toByteArray()))
    }
}
