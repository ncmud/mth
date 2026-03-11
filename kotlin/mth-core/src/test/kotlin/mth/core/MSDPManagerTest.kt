package mth.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertNotNull
import kotlin.test.assertContentEquals

private const val IAC: Byte = 0xFF.toByte()
private const val SB: Byte = 0xFA.toByte()
private const val SE: Byte = 0xF0.toByte()
private const val TELOPT_MSDP: Byte = 69
private const val TELOPT_GMCP: Byte = 0xC9.toByte()
private const val MV: Byte = 1  // MSDP_VAR
private const val ML: Byte = 2  // MSDP_VAL
private const val AO: Byte = 5  // MSDP_ARRAY_OPEN
private const val AC: Byte = 6  // MSDP_ARRAY_CLOSE

private fun textBytes(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

/** Parse an MSDP array (sequence of MSDP_VAL + string) into string values. */
private fun parseMSDPArray(bytes: ByteArray): List<String> {
    val result = mutableListOf<String>()
    var i = 0
    while (i < bytes.size) {
        if (bytes[i] == ML) {
            i++
            val name = mutableListOf<Byte>()
            while (i < bytes.size && bytes[i] != ML && bytes[i] != AC) {
                name.add(bytes[i])
                i++
            }
            if (name.isNotEmpty()) {
                result.add(String(name.toByteArray(), Charsets.UTF_8))
            }
        } else {
            i++
        }
    }
    return result
}

/** Extract the array bytes from a LIST command response packet. */
private fun extractArrayFromListPacket(packet: ByteArray, varName: String): ByteArray {
    val headerLen = 4 + varName.toByteArray(Charsets.UTF_8).size + 2 // IAC SB MSDP MV + name + ML AO
    val trailerLen = 3 // AC IAC SE
    if (packet.size <= headerLen + trailerLen) return byteArrayOf()
    return packet.copyOfRange(headerLen, packet.size - trailerLen)
}

class MSDPManagerTest {

    // -- Table Verification --

    @Test fun tableIsSorted() {
        val names = defaultMSDPTable.map { it.name }
        for (i in 1 until names.size) {
            assertTrue(names[i - 1] < names[i],
                "${names[i - 1]} should sort before ${names[i]}")
        }
    }

    @Test fun tableContentsMatchCSource() {
        val table = defaultMSDPTable
        val byName = table.associate { it.name to it.flags }

        assertEquals(27, table.size)

        // MSDP_FLAG_SENDABLE|MSDP_FLAG_REPORTABLE = 4|8 = 12
        assertEquals(12, byName["HEALTH"]?.rawValue)
        assertEquals(12, byName["MANA"]?.rawValue)
        assertEquals(12, byName["LEVEL"]?.rawValue)

        // MSDP_FLAG_COMMAND = 1
        assertEquals(1, byName["LIST"]?.rawValue)
        assertEquals(1, byName["REPORT"]?.rawValue)
        assertEquals(1, byName["SEND"]?.rawValue)
        assertEquals(1, byName["UNREPORT"]?.rawValue)
        assertEquals(1, byName["RESET"]?.rawValue)

        // MSDP_FLAG_COMMAND|MSDP_FLAG_LIST = 1|2 = 3
        assertEquals(3, byName["COMMANDS"]?.rawValue)

        // MSDP_FLAG_LIST = 2
        assertEquals(2, byName["LISTS"]?.rawValue)

        // MSDP_FLAG_CONFIGURABLE|MSDP_FLAG_REPORTABLE = 16|8 = 24
        assertEquals(24, byName["ARACHNOS_DEVEL"]?.rawValue)

        // MSDP_FLAG_CONFIGURABLE = 16
        assertEquals(16, byName["ARACHNOS_MUDLIST"]?.rawValue)

        // MSDP_FLAG_REPORTABLE = 8
        assertEquals(8, byName["ROOM"]?.rawValue)

        // MSDP_FLAG_SENDABLE = 4
        assertEquals(4, byName["SPECIFICATION"]?.rawValue)

        // MSDP_FLAG_REPORTABLE|MSDP_FLAG_LIST = 8|2 = 10
        assertEquals(10, byName["REPORTABLE_VARIABLES"]?.rawValue)

        // MSDP_FLAG_REPORTED|MSDP_FLAG_LIST = 32|2 = 34
        assertEquals(34, byName["REPORTED_VARIABLES"]?.rawValue)
    }

    // -- Packet Format --

    @Test fun updateVariableImmediatePacketFormat() {
        var captured = byteArrayOf()
        val mgr = MSDPManager(writeHandler = { captured = it })

        mgr.processVarVal("REPORT", "HEALTH")
        captured = byteArrayOf()

        mgr.updateVariableImmediate("HEALTH", "95")

        val expected = byteArrayOf(IAC, SB, TELOPT_MSDP, MV) +
            textBytes("HEALTH") + byteArrayOf(ML) + textBytes("95") + byteArrayOf(IAC, SE)

        assertContentEquals(expected, captured, "Instant update packet mismatch")
    }

    @Test fun flushUpdatesPacketFormat() {
        val captured = mutableListOf<ByteArray>()
        val mgr = MSDPManager(writeHandler = { captured.add(it.copyOf()) })

        mgr.processVarVal("REPORT", "HEALTH")
        mgr.processVarVal("REPORT", "MANA")
        captured.clear()

        mgr.updateVariable("HEALTH", "100")
        mgr.updateVariable("MANA", "50")

        assertTrue(mgr.needsUpdate)

        mgr.flushUpdates()

        assertFalse(mgr.needsUpdate)
        assertEquals(1, captured.size)

        val packet = captured[0]

        val expected = byteArrayOf(IAC, SB, TELOPT_MSDP) +
            byteArrayOf(MV) + textBytes("HEALTH") + byteArrayOf(ML) + textBytes("100") +
            byteArrayOf(MV) + textBytes("MANA") + byteArrayOf(ML) + textBytes("50") +
            byteArrayOf(IAC, SE)

        assertContentEquals(expected, packet, "Flush packet mismatch")
    }

    @Test fun flushUpdatesNoopWhenNoChanges() {
        val captured = mutableListOf<ByteArray>()
        val mgr = MSDPManager(writeHandler = { captured.add(it.copyOf()) })

        mgr.processVarVal("REPORT", "HEALTH")
        mgr.flushUpdates()
        captured.clear()

        mgr.flushUpdates()

        assertTrue(captured.isEmpty(), "Should not send packet when nothing updated")
    }

    // -- GMCP Conversion --

    @Test fun gmcpModeConvertsPackets() {
        var captured = byteArrayOf()
        val mgr = MSDPManager(writeHandler = { captured = it })
        mgr.usesGMCP = true

        mgr.processVarVal("REPORT", "HEALTH")
        captured = byteArrayOf()

        mgr.updateVariableImmediate("HEALTH", "42")

        assertEquals(IAC, captured[0])
        assertEquals(SB, captured[1])
        assertEquals(TELOPT_GMCP, captured[2])

        assertEquals(IAC, captured[captured.size - 2])
        assertEquals(SE, captured[captured.size - 1])

        val jsonPortion = String(captured.copyOfRange(3, captured.size - 2), Charsets.UTF_8)
        assertTrue(jsonPortion.contains("HEALTH"), "GMCP should contain variable name")
        assertTrue(jsonPortion.contains("42"), "GMCP should contain value")
    }

    // -- State Transitions --

    @Test fun reportEnablesReporting() {
        val mgr = MSDPManager(writeHandler = { })

        mgr.processVarVal("REPORT", "HEALTH")

        assertTrue(mgr.needsUpdate)
    }

    @Test fun unreportDisablesReporting() {
        val mgr = MSDPManager(writeHandler = { })

        mgr.processVarVal("REPORT", "HEALTH")
        mgr.flushUpdates()

        mgr.processVarVal("UNREPORT", "HEALTH")

        mgr.updateVariable("HEALTH", "99")
        assertFalse(mgr.needsUpdate)
    }

    @Test fun sendQueuesUpdate() {
        val captured = mutableListOf<ByteArray>()
        val mgr = MSDPManager(writeHandler = { captured.add(it.copyOf()) })

        mgr.updateVariable("HEALTH", "100")
        captured.clear()

        mgr.processVarVal("SEND", "HEALTH")
        assertTrue(mgr.needsUpdate)

        mgr.flushUpdates()
        assertEquals(1, captured.size)
    }

    @Test fun updateVariableOnlyQueuesOnChange() {
        val mgr = MSDPManager(writeHandler = { })

        mgr.processVarVal("REPORT", "HEALTH")
        mgr.flushUpdates()

        mgr.updateVariable("HEALTH", "100")
        assertTrue(mgr.needsUpdate)
        mgr.flushUpdates()

        mgr.updateVariable("HEALTH", "100")
        assertFalse(mgr.needsUpdate)
    }

    @Test fun getVariableReturnsValue() {
        val mgr = MSDPManager(writeHandler = { })

        assertEquals("", mgr.getVariable("HEALTH"))

        mgr.updateVariable("HEALTH", "100")
        assertEquals("100", mgr.getVariable("HEALTH"))
    }

    @Test fun getVariableReturnsNilForUnknown() {
        val logMessages = mutableListOf<String>()
        val mgr = MSDPManager(
            writeHandler = { },
            logHandler = { logMessages.add(it) }
        )

        val result = mgr.getVariable("NONEXISTENT")
        assertNull(result)
        assertEquals(1, logMessages.size)
    }

    // -- LIST Commands --

    @Test fun listCommandSendableVariables() {
        var captured = byteArrayOf()
        val mgr = MSDPManager(writeHandler = { captured = it })

        mgr.processVarVal("LIST", "SENDABLE_VARIABLES")

        assertEquals(IAC, captured[0])
        assertEquals(SB, captured[1])
        assertEquals(TELOPT_MSDP, captured[2])
        assertEquals(MV, captured[3])

        val headerEnd = 4 + textBytes("SENDABLE_VARIABLES").size
        assertEquals(ML, captured[headerEnd])
        assertEquals(AO, captured[headerEnd + 1])

        assertEquals(AC, captured[captured.size - 3])
        assertEquals(IAC, captured[captured.size - 2])
        assertEquals(SE, captured[captured.size - 1])

        val arrayBytes = captured.copyOfRange(headerEnd + 2, captured.size - 3)
        val content = parseMSDPArray(arrayBytes)
        val sendableNames = defaultMSDPTable
            .filter { MSDPFlags.SENDABLE in it.flags && MSDPFlags.LIST !in it.flags }
            .map { it.name }

        assertEquals(sendableNames.toSet(), content.toSet(),
            "LIST SENDABLE_VARIABLES should return all sendable non-list vars")
    }

    @Test fun listCommandLists() {
        var captured = byteArrayOf()
        val mgr = MSDPManager(writeHandler = { captured = it })

        mgr.processVarVal("LIST", "LISTS")

        val arrayBytes = extractArrayFromListPacket(captured, "LISTS")
        val content = parseMSDPArray(arrayBytes)
        val listNames = defaultMSDPTable
            .filter { MSDPFlags.LIST in it.flags }
            .map { it.name }

        assertEquals(listNames.toSet(), content.toSet(),
            "LIST LISTS should return all list vars")
    }

    @Test fun listCommandWithArray() {
        val captured = mutableListOf<ByteArray>()
        val mgr = MSDPManager(writeHandler = { captured.add(it.copyOf()) })

        val arrayBytes = byteArrayOf(AO, ML) +
            textBytes("SENDABLE_VARIABLES") +
            byteArrayOf(ML) +
            textBytes("REPORTABLE_VARIABLES") +
            byteArrayOf(AC)
        val arrayArg = String(arrayBytes, Charsets.UTF_8)

        mgr.processVarVal("LIST", arrayArg)

        assertEquals(2, captured.size, "Should produce two LIST responses")
    }

    // -- Round-trip with msdp2json --

    @Test fun managerOutputConvertsToValidGMCP() {
        var captured = byteArrayOf()
        val mgr = MSDPManager(writeHandler = { captured = it })

        mgr.processVarVal("REPORT", "HEALTH")
        mgr.processVarVal("REPORT", "LEVEL")
        mgr.flushUpdates()
        captured = byteArrayOf()

        mgr.updateVariable("HEALTH", "100")
        mgr.updateVariable("LEVEL", "5")
        mgr.flushUpdates()

        val json = msdp2json(captured)

        assertEquals(IAC, json[0])
        assertEquals(SB, json[1])
        assertEquals(TELOPT_GMCP, json[2])
        assertEquals(IAC, json[json.size - 2])
        assertEquals(SE, json[json.size - 1])

        val content = String(json.copyOfRange(3, json.size - 2), Charsets.UTF_8)
        assertTrue(content.contains("HEALTH"), "Should contain HEALTH")
        assertTrue(content.contains("100"), "Should contain value 100")
        assertTrue(content.contains("LEVEL"), "Should contain LEVEL")
        assertTrue(content.contains("5"), "Should contain value 5")
    }
}
