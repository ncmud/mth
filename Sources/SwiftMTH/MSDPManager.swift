// MSDP protocol control bytes (shared with MSDPConverter.swift)
private let MSDP_VAR: UInt8 = 1
private let MSDP_VAL: UInt8 = 2
private let MSDP_TABLE_OPEN: UInt8 = 3
private let MSDP_TABLE_CLOSE: UInt8 = 4
private let MSDP_ARRAY_OPEN: UInt8 = 5
private let MSDP_ARRAY_CLOSE: UInt8 = 6

private let IAC: UInt8 = 255
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let TELOPT_MSDP: UInt8 = 69

/// Callback for writing MSDP data to the connection.
public typealias MSDPWriteHandler = ([UInt8]) -> Void

/// Callback for logging.
public typealias MSDPLogHandler = (String) -> Void

/// Manages MSDP variable state for a single connection.
///
/// Replaces the C per-connection `msdp_data` array and the global `msdp_table`
/// functions. Each `MSDPManager` instance corresponds to one telnet session.
///
/// Not `Sendable` — intended for use on a single thread/connection.
public final class MSDPManager {
    /// Variable definitions (shared, immutable).
    private let definitions: [MSDPVariableDefinition]

    /// Fast lookup from variable name to index in `definitions`.
    private let nameIndex: [String: Int]

    /// Per-connection variable state, indexed by position in `definitions`.
    private var state: [MSDPVariableState]

    /// Whether any variable needs to be flushed via `flushUpdates()`.
    public private(set) var needsUpdate: Bool = false

    /// Whether this connection uses GMCP (JSON) instead of raw MSDP.
    public var usesGMCP: Bool = false

    /// Called to write bytes to the connection.
    public let writeHandler: MSDPWriteHandler

    /// Called for log messages.
    public let logHandler: MSDPLogHandler

    public init(
        table: [MSDPVariableDefinition] = defaultMSDPTable,
        writeHandler: @escaping MSDPWriteHandler,
        logHandler: @escaping MSDPLogHandler = { _ in }
    ) {
        self.definitions = table
        var index: [String: Int] = [:]
        index.reserveCapacity(table.count)
        for (i, def) in table.enumerated() {
            index[def.name] = i
        }
        self.nameIndex = index
        self.state = table.map { def in
            MSDPVariableState(value: "", flags: def.flags)
        }
        self.writeHandler = writeHandler
        self.logHandler = logHandler
    }

    // MARK: - Variable Lookup

    /// Find the index of a variable by name. Returns nil if not found.
    private func findIndex(_ name: String) -> Int? {
        nameIndex[name]
    }

    // MARK: - Reading

    /// Get the current value of a variable, or nil if unknown.
    public func getVariable(_ name: String) -> String? {
        guard let idx = findIndex(name) else {
            logHandler("msdp_get_var: Unknown variable: \(name).")
            return nil
        }
        return state[idx].value
    }

    // MARK: - Updating

    /// Update a variable's value. If the variable is being reported and the
    /// value changed, queues it for the next `flushUpdates()` call.
    ///
    /// Equivalent to C `msdp_update_var`.
    public func updateVariable(_ name: String, value: String) {
        guard let idx = findIndex(name) else {
            logHandler("msdp_update_var: Unknown variable: \(name).")
            return
        }

        if state[idx].value != value {
            if state[idx].flags.contains(.reported) {
                state[idx].flags.insert(.updated)
                needsUpdate = true
            }
            state[idx].value = value
        }
    }

    /// Update a variable's value and immediately send it if reported.
    ///
    /// Equivalent to C `msdp_update_var_instant`.
    public func updateVariableImmediate(_ name: String, value: String) {
        guard let idx = findIndex(name) else {
            logHandler("msdp_update_var_instant: Unknown variable: \(name).")
            return
        }

        if state[idx].value != value {
            state[idx].value = value
        }

        if state[idx].flags.contains(.reported) {
            var packet: [UInt8] = [IAC, SB, TELOPT_MSDP]
            packet.append(MSDP_VAR)
            packet.append(contentsOf: definitions[idx].name.utf8)
            packet.append(MSDP_VAL)
            packet.append(contentsOf: value.utf8)
            packet.append(IAC)
            packet.append(SE)
            writeMSDP(packet)
        }
    }

    /// Send all reported variables that have been updated since the last flush.
    ///
    /// Equivalent to C `msdp_send_update`.
    public func flushUpdates() {
        var packet: [UInt8] = [IAC, SB, TELOPT_MSDP]
        var hasContent = false

        for idx in 0..<definitions.count {
            if state[idx].flags.contains(.updated) {
                packet.append(MSDP_VAR)
                packet.append(contentsOf: definitions[idx].name.utf8)
                packet.append(MSDP_VAL)
                packet.append(contentsOf: state[idx].value.utf8)
                state[idx].flags.remove(.updated)
                hasContent = true
            }
        }

        packet.append(IAC)
        packet.append(SE)

        if hasContent {
            writeMSDP(packet)
        }

        needsUpdate = false
    }

    // MARK: - Client Commands

    /// Process an incoming MSDP variable/value pair from the client.
    ///
    /// Equivalent to C `process_msdp_varval`.
    public func processVarVal(_ variable: String, value: String) {
        guard let varIdx = findIndex(variable) else { return }
        let def = definitions[varIdx]

        if def.flags.contains(.configurable) {
            state[varIdx].value = value
            handleCommand(varIdx)
            return
        }

        if def.flags.contains(.command) {
            if !value.isEmpty && value.utf8.first == MSDP_ARRAY_OPEN {
                processArray(varIdx, value: value)
            } else {
                guard let valIdx = findIndex(value) else { return }
                handleCommandWithArgument(varIdx, argumentIndex: valIdx)
            }
        }
    }

    /// Process a 1D array argument for a command variable.
    private func processArray(_ varIdx: Int, value: String) {
        let bytes = Array(value.utf8)
        var i = 0
        var buf: [UInt8] = []

        while i < bytes.count {
            switch bytes[i] {
            case MSDP_ARRAY_OPEN:
                i += 1
            case MSDP_VAL:
                if !buf.isEmpty {
                    let name = String(decoding: buf, as: UTF8.self)
                    if let argIdx = findIndex(name) {
                        handleCommandWithArgument(varIdx, argumentIndex: argIdx)
                    }
                }
                buf.removeAll()
                i += 1
            case MSDP_ARRAY_CLOSE:
                if !buf.isEmpty {
                    let name = String(decoding: buf, as: UTF8.self)
                    if let argIdx = findIndex(name) {
                        handleCommandWithArgument(varIdx, argumentIndex: argIdx)
                    }
                }
                return
            default:
                buf.append(bytes[i])
                i += 1
            }
        }

        if !buf.isEmpty {
            let name = String(decoding: buf, as: UTF8.self)
            if let argIdx = findIndex(name) {
                handleCommandWithArgument(varIdx, argumentIndex: argIdx)
            }
        }
    }

    /// Dispatch a command with no argument (configurable variable handler).
    private func handleCommand(_ varIdx: Int) {
        let name = definitions[varIdx].name
        switch name {
        case "ARACHNOS_DEVEL", "ARACHNOS_MUDLIST":
            // Arachnos handlers are MUD-specific; delegate up
            break
        default:
            break
        }
    }

    /// Dispatch a command with a variable-index argument.
    ///
    /// The C code uses function pointers; we use a switch on the command name.
    private func handleCommandWithArgument(_ cmdIdx: Int, argumentIndex argIdx: Int) {
        let name = definitions[cmdIdx].name
        switch name {
        case "LIST":
            commandList(argIdx)
        case "REPORT":
            commandReport(argIdx)
        case "UNREPORT":
            commandUnreport(argIdx)
        case "SEND":
            commandSend(argIdx)
        case "RESET":
            commandReset(argIdx)
        default:
            break
        }
    }

    // MARK: - Command Implementations

    /// LIST command: send a list of variables matching the requested category.
    ///
    /// Equivalent to C `msdp_command_list`.
    private func commandList(_ index: Int) {
        let def = definitions[index]
        guard def.flags.contains(.list) else { return }

        var packet: [UInt8] = [IAC, SB, TELOPT_MSDP]
        packet.append(MSDP_VAR)
        packet.append(contentsOf: def.name.utf8)
        packet.append(MSDP_VAL)
        packet.append(MSDP_ARRAY_OPEN)

        let flag = def.flags.subtracting(.list)

        for idx in 0..<definitions.count {
            if !flag.isEmpty {
                // List variables matching the flag (excluding other list vars)
                if state[idx].flags.contains(flag) && !state[idx].flags.contains(.list) {
                    packet.append(MSDP_VAL)
                    packet.append(contentsOf: definitions[idx].name.utf8)
                }
            } else {
                // flag is empty after removing .list -> this is "LISTS", list all list variables
                if state[idx].flags.contains(.list) {
                    packet.append(MSDP_VAL)
                    packet.append(contentsOf: definitions[idx].name.utf8)
                }
            }
        }

        packet.append(MSDP_ARRAY_CLOSE)
        packet.append(IAC)
        packet.append(SE)

        writeMSDP(packet)
    }

    /// REPORT command: enable auto-reporting for a variable.
    ///
    /// Equivalent to C `msdp_command_report`.
    private func commandReport(_ index: Int) {
        guard definitions[index].flags.contains(.reportable) else { return }

        state[index].flags.insert(.reported)

        guard definitions[index].flags.contains(.sendable) else { return }

        state[index].flags.insert(.updated)
        needsUpdate = true
    }

    /// UNREPORT command: disable auto-reporting for a variable.
    ///
    /// Equivalent to C `msdp_command_unreport`.
    private func commandUnreport(_ index: Int) {
        guard definitions[index].flags.contains(.reportable) else { return }
        state[index].flags.remove(.reported)
    }

    /// SEND command: queue a sendable variable for immediate update.
    ///
    /// Equivalent to C `msdp_command_send`.
    private func commandSend(_ index: Int) {
        if state[index].flags.contains(.sendable) {
            state[index].flags.insert(.updated)
            needsUpdate = true
        }
    }

    /// RESET command: reset all variables matching the list's flag.
    ///
    /// Equivalent to C `msdp_command_reset`.
    private func commandReset(_ index: Int) {
        guard definitions[index].flags.contains(.list) else { return }

        let flag = definitions[index].flags.subtracting(.list)

        for idx in 0..<definitions.count {
            if state[idx].flags.contains(flag) {
                state[idx].flags = definitions[idx].flags
            }
        }
    }

    // MARK: - Output

    /// Write an MSDP packet, converting to GMCP JSON if needed.
    ///
    /// Equivalent to C `write_msdp_to_descriptor`.
    private func writeMSDP(_ packet: [UInt8]) {
        if usesGMCP {
            let json = msdp2json(packet)
            writeHandler(json)
        } else {
            writeHandler(packet)
        }
    }
}
