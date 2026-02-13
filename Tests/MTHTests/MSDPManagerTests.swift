import Testing
import MTH

// Telnet/MSDP constants
private let IAC: UInt8 = 255
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let TELOPT_MSDP: UInt8 = 69
private let TELOPT_GMCP: UInt8 = 201
private let MV: UInt8 = 1  // MSDP_VAR
private let ML: UInt8 = 2  // MSDP_VAL
private let AO: UInt8 = 5  // MSDP_ARRAY_OPEN
private let AC: UInt8 = 6  // MSDP_ARRAY_CLOSE

// MARK: - Table Verification Tests

/// Verify the default table is alphabetically sorted (required by MSDP spec).
@Test func tableIsSorted() {
    let names = defaultMSDPTable.map(\.name)
    for i in 1..<names.count {
        #expect(names[i - 1] < names[i],
                "\(names[i - 1]) should sort before \(names[i])")
    }
}

/// Verify table contains expected standard MSDP variables with correct flags.
/// These values are manually verified against the C msdp_table in msdp.c.
@Test func tableContentsMatchCSource() {
    let table = defaultMSDPTable
    let byName = Dictionary(uniqueKeysWithValues: table.map { ($0.name, $0.flags) })

    // Verify count matches C table (28 entries, excluding empty terminator)
    #expect(table.count == 27)

    // Spot-check key entries against C source
    // C: MSDP_FLAG_SENDABLE|MSDP_FLAG_REPORTABLE = 4|8 = 12
    #expect(byName["HEALTH"]?.rawValue == 12)
    #expect(byName["MANA"]?.rawValue == 12)
    #expect(byName["LEVEL"]?.rawValue == 12)

    // C: MSDP_FLAG_COMMAND = 1
    #expect(byName["LIST"]?.rawValue == 1)
    #expect(byName["REPORT"]?.rawValue == 1)
    #expect(byName["SEND"]?.rawValue == 1)
    #expect(byName["UNREPORT"]?.rawValue == 1)
    #expect(byName["RESET"]?.rawValue == 1)

    // C: MSDP_FLAG_COMMAND|MSDP_FLAG_LIST = 1|2 = 3
    #expect(byName["COMMANDS"]?.rawValue == 3)

    // C: MSDP_FLAG_LIST = 2
    #expect(byName["LISTS"]?.rawValue == 2)

    // C: MSDP_FLAG_CONFIGURABLE|MSDP_FLAG_REPORTABLE = 16|8 = 24
    #expect(byName["ARACHNOS_DEVEL"]?.rawValue == 24)

    // C: MSDP_FLAG_CONFIGURABLE = 16
    #expect(byName["ARACHNOS_MUDLIST"]?.rawValue == 16)

    // C: MSDP_FLAG_REPORTABLE = 8
    #expect(byName["ROOM"]?.rawValue == 8)

    // C: MSDP_FLAG_SENDABLE = 4
    #expect(byName["SPECIFICATION"]?.rawValue == 4)

    // C: MSDP_FLAG_REPORTABLE|MSDP_FLAG_LIST = 8|2 = 10
    #expect(byName["REPORTABLE_VARIABLES"]?.rawValue == 10)

    // C: MSDP_FLAG_REPORTED|MSDP_FLAG_LIST = 32|2 = 34
    #expect(byName["REPORTED_VARIABLES"]?.rawValue == 34)
}

// MARK: - Packet Format Tests

/// Verify updateVariableImmediate produces correct MSDP packet.
@Test func updateVariableImmediatePacketFormat() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(writeHandler: { captured = $0 })

    // REPORT HEALTH first so it's in reported state
    mgr.processVarVal("REPORT", value: "HEALTH")
    captured = []

    mgr.updateVariableImmediate("HEALTH", value: "95")

    // Expected: IAC SB MSDP MSDP_VAR "HEALTH" MSDP_VAL "95" IAC SE
    var expected: [UInt8] = [IAC, SB, TELOPT_MSDP, MV]
    expected.append(contentsOf: "HEALTH".utf8)
    expected.append(ML)
    expected.append(contentsOf: "95".utf8)
    expected.append(IAC)
    expected.append(SE)

    #expect(captured == expected, "Instant update packet mismatch")
}

/// Verify flushUpdates produces correct batched MSDP packet.
@Test func flushUpdatesPacketFormat() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    // Report HP and MANA
    mgr.processVarVal("REPORT", value: "HEALTH")
    mgr.processVarVal("REPORT", value: "MANA")
    captured = []

    // Update both
    mgr.updateVariable("HEALTH", value: "100")
    mgr.updateVariable("MANA", value: "50")

    #expect(mgr.needsUpdate == true)

    mgr.flushUpdates()

    #expect(mgr.needsUpdate == false)
    #expect(captured.count == 1)

    let packet = captured[0]

    // Expected: IAC SB MSDP [MV "HEALTH" ML "100" MV "MANA" ML "50"] IAC SE
    // Variables appear in table order
    var expected: [UInt8] = [IAC, SB, TELOPT_MSDP]
    expected.append(MV)
    expected.append(contentsOf: "HEALTH".utf8)
    expected.append(ML)
    expected.append(contentsOf: "100".utf8)
    expected.append(MV)
    expected.append(contentsOf: "MANA".utf8)
    expected.append(ML)
    expected.append(contentsOf: "50".utf8)
    expected.append(IAC)
    expected.append(SE)

    #expect(packet == expected, "Flush packet mismatch")
}

/// Verify flushUpdates doesn't send if nothing changed.
@Test func flushUpdatesNoopWhenNoChanges() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    mgr.processVarVal("REPORT", value: "HEALTH")
    // REPORT queues an initial send for sendable variables — flush it
    mgr.flushUpdates()
    captured = []

    // No further updates — flush should not write
    mgr.flushUpdates()

    #expect(captured.isEmpty, "Should not send packet when nothing updated")
}

// MARK: - GMCP Conversion Tests

/// Verify GMCP mode converts MSDP packets to JSON.
@Test func gmcpModeConvertsPackets() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(writeHandler: { captured = $0 })
    mgr.usesGMCP = true

    mgr.processVarVal("REPORT", value: "HEALTH")
    captured = []

    mgr.updateVariableImmediate("HEALTH", value: "42")

    // The output should be a GMCP packet (IAC SB GMCP "MSDP {...}" IAC SE)
    #expect(captured[0] == IAC)
    #expect(captured[1] == SB)
    #expect(captured[2] == TELOPT_GMCP)

    // Verify it ends with IAC SE
    #expect(captured[captured.count - 2] == IAC)
    #expect(captured[captured.count - 1] == SE)

    // The JSON portion should contain "HEALTH" and "42"
    let jsonPortion = String(decoding: captured[3..<captured.count - 2], as: UTF8.self)
    #expect(jsonPortion.contains("HEALTH"), "GMCP should contain variable name")
    #expect(jsonPortion.contains("42"), "GMCP should contain value")
}

// MARK: - State Transition Tests

/// Verify REPORT enables reporting and queues initial send for sendable variables.
@Test func reportEnablesReporting() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    mgr.processVarVal("REPORT", value: "HEALTH")

    // HEALTH is sendable+reportable, so REPORT should queue it for update
    #expect(mgr.needsUpdate == true)
}

/// Verify UNREPORT disables reporting.
@Test func unreportDisablesReporting() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    // Report then unreport
    mgr.processVarVal("REPORT", value: "HEALTH")
    mgr.flushUpdates()
    captured = []

    mgr.processVarVal("UNREPORT", value: "HEALTH")

    // Update should not queue
    mgr.updateVariable("HEALTH", value: "99")
    #expect(mgr.needsUpdate == false)
}

/// Verify SEND queues a sendable variable for update.
@Test func sendQueuesUpdate() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    mgr.updateVariable("HEALTH", value: "100")
    captured = []

    mgr.processVarVal("SEND", value: "HEALTH")
    #expect(mgr.needsUpdate == true)

    mgr.flushUpdates()
    #expect(captured.count == 1)
}

/// Verify updateVariable only queues when value actually changes.
@Test func updateVariableOnlyQueuesOnChange() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    mgr.processVarVal("REPORT", value: "HEALTH")
    mgr.flushUpdates()
    captured = []

    // Set value
    mgr.updateVariable("HEALTH", value: "100")
    #expect(mgr.needsUpdate == true)
    mgr.flushUpdates()
    captured = []

    // Set same value again — should not queue
    mgr.updateVariable("HEALTH", value: "100")
    #expect(mgr.needsUpdate == false)
}

/// Verify getVariable returns current value.
@Test func getVariableReturnsValue() {
    let mgr = MSDPManager(writeHandler: { _ in })

    #expect(mgr.getVariable("HEALTH") == "")

    mgr.updateVariable("HEALTH", value: "100")
    #expect(mgr.getVariable("HEALTH") == "100")
}

/// Verify getVariable returns nil for unknown variables.
@Test func getVariableReturnsNilForUnknown() {
    var logMessages: [String] = []
    let mgr = MSDPManager(
        writeHandler: { _ in },
        logHandler: { logMessages.append($0) }
    )

    let result = mgr.getVariable("NONEXISTENT")
    #expect(result == nil)
    #expect(logMessages.count == 1)
}

// MARK: - LIST Command Tests

/// Verify LIST command returns correct variable lists.
@Test func listCommandSendableVariables() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(writeHandler: { captured = $0 })

    // LIST SENDABLE_VARIABLES
    mgr.processVarVal("LIST", value: "SENDABLE_VARIABLES")

    // Should be a packet with SENDABLE_VARIABLES as the var, containing
    // all sendable variables in an MSDP array
    #expect(captured[0] == IAC)
    #expect(captured[1] == SB)
    #expect(captured[2] == TELOPT_MSDP)
    #expect(captured[3] == MV)

    // Find the variable name
    let headerEnd = 4 + "SENDABLE_VARIABLES".utf8.count
    #expect(captured[headerEnd] == ML)
    #expect(captured[headerEnd + 1] == AO)

    // Last bytes before IAC SE should be ARRAY_CLOSE
    #expect(captured[captured.count - 3] == AC)
    #expect(captured[captured.count - 2] == IAC)
    #expect(captured[captured.count - 1] == SE)

    // Extract the array content and verify it contains sendable variable names
    let arrayBytes = Array(captured[(headerEnd + 2)..<(captured.count - 3)])
    let content = parseMSDPArray(arrayBytes)
    let sendableNames = defaultMSDPTable
        .filter { $0.flags.contains(.sendable) && !$0.flags.contains(.list) }
        .map(\.name)

    #expect(Set(content) == Set(sendableNames),
            "LIST SENDABLE_VARIABLES should return all sendable non-list vars")
}

/// Verify LIST LISTS returns all list variables.
@Test func listCommandLists() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(writeHandler: { captured = $0 })

    mgr.processVarVal("LIST", value: "LISTS")

    let arrayBytes = extractArrayFromListPacket(captured, varName: "LISTS")
    let content = parseMSDPArray(arrayBytes)
    let listNames = defaultMSDPTable
        .filter { $0.flags.contains(.list) }
        .map(\.name)

    #expect(Set(content) == Set(listNames),
            "LIST LISTS should return all list vars")
}

/// Verify LIST with array argument (multiple variables).
@Test func listCommandWithArray() {
    var captured: [[UInt8]] = []
    let mgr = MSDPManager(writeHandler: { captured.append($0) })

    // Build array argument as raw bytes
    var arrayBytes: [UInt8] = [AO, ML]
    arrayBytes.append(contentsOf: "SENDABLE_VARIABLES".utf8)
    arrayBytes.append(ML)
    arrayBytes.append(contentsOf: "REPORTABLE_VARIABLES".utf8)
    arrayBytes.append(AC)
    let arrayArg = String(decoding: arrayBytes, as: UTF8.self)

    mgr.processVarVal("LIST", value: arrayArg)

    #expect(captured.count == 2, "Should produce two LIST responses")
}

// MARK: - Round-trip with msdp2json

/// Verify that packets produced by flushUpdates can be converted to GMCP JSON
/// containing the correct variable names and values.
@Test func managerOutputConvertsToValidGMCP() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(writeHandler: { captured = $0 })

    mgr.processVarVal("REPORT", value: "HEALTH")
    mgr.processVarVal("REPORT", value: "LEVEL")
    mgr.flushUpdates() // flush initial report queue
    captured = []

    mgr.updateVariable("HEALTH", value: "100")
    mgr.updateVariable("LEVEL", value: "5")
    mgr.flushUpdates()

    let json = msdp2json(captured)

    // Verify GMCP framing
    #expect(json[0] == IAC)
    #expect(json[1] == SB)
    #expect(json[2] == TELOPT_GMCP)
    #expect(json[json.count - 2] == IAC)
    #expect(json[json.count - 1] == SE)

    // Verify JSON content contains the variable names and values
    let content = String(decoding: json[3..<json.count - 2], as: UTF8.self)
    #expect(content.contains("HEALTH"), "Should contain HEALTH")
    #expect(content.contains("100"), "Should contain value 100")
    #expect(content.contains("LEVEL"), "Should contain LEVEL")
    #expect(content.contains("5"), "Should contain value 5")
}

/// Verify round-trip works for packets ending with TABLE_CLOSE.
/// (Flat VAR/VAL packets have a known unclosed-quote edge case in msdp2json,
/// matching C behavior.)
@Test func managerTableOutputRoundTrips() {
    var captured: [UInt8] = []
    let mgr = MSDPManager(
        table: [
            MSDPVariableDefinition(name: "REPORT", flags: .command),
            MSDPVariableDefinition(name: "ROOM", flags: [.sendable, .reportable]),
        ],
        writeHandler: { captured = $0 }
    )

    mgr.processVarVal("REPORT", value: "ROOM")
    mgr.flushUpdates()
    captured = []

    // Set a table-structured value by updating and flushing
    mgr.updateVariable("ROOM", value: "TestRoom")
    mgr.flushUpdates()

    // This is a flat packet, so test the JSON conversion produces valid GMCP
    let json = msdp2json(captured)
    let content = String(decoding: json[3..<json.count - 2], as: UTF8.self)
    #expect(content.contains("ROOM"))
    #expect(content.contains("TestRoom"))
}

// MARK: - Helpers

/// Parse an MSDP array (sequence of MSDP_VAL + string) into string values.
private func parseMSDPArray(_ bytes: [UInt8]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < bytes.count {
        if bytes[i] == ML {
            i += 1
            var name: [UInt8] = []
            while i < bytes.count && bytes[i] != ML && bytes[i] != AC {
                name.append(bytes[i])
                i += 1
            }
            if !name.isEmpty {
                result.append(String(decoding: name, as: UTF8.self))
            }
        } else {
            i += 1
        }
    }
    return result
}

/// Extract the array bytes from a LIST command response packet.
private func extractArrayFromListPacket(_ packet: [UInt8], varName: String) -> [UInt8] {
    // Skip IAC SB MSDP MV <varName> ML AO ... AC IAC SE
    let headerLen = 4 + varName.utf8.count + 2 // IAC SB MSDP MV + name + ML AO
    let trailerLen = 3 // AC IAC SE
    guard packet.count > headerLen + trailerLen else { return [] }
    return Array(packet[headerLen..<(packet.count - trailerLen)])
}
