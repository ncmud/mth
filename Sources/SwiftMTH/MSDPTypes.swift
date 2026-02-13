/// Flags for MSDP variable definitions and per-connection variable state.
///
/// Definition flags (set on the variable definition, shared across connections):
/// - `command`: This variable is a command (LIST, REPORT, SEND, etc.)
/// - `list`: This variable is a list category
/// - `sendable`: Value can be sent on demand
/// - `reportable`: Value can be auto-reported on change
/// - `configurable`: Value can be set by the client
///
/// Per-connection state flags (set per session):
/// - `reported`: Currently being auto-reported for this connection
/// - `updated`: Has changed since last flush
public struct MSDPFlags: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command      = MSDPFlags(rawValue: 1 << 0)
    public static let list         = MSDPFlags(rawValue: 1 << 1)
    public static let sendable     = MSDPFlags(rawValue: 1 << 2)
    public static let reportable   = MSDPFlags(rawValue: 1 << 3)
    public static let configurable = MSDPFlags(rawValue: 1 << 4)
    public static let reported     = MSDPFlags(rawValue: 1 << 5)
    public static let updated      = MSDPFlags(rawValue: 1 << 6)
}

/// Definition of a single MSDP variable in the table.
public struct MSDPVariableDefinition: Sendable {
    public let name: String
    public let flags: MSDPFlags

    public init(name: String, flags: MSDPFlags) {
        self.name = name
        self.flags = flags
    }
}

/// Per-connection state for a single MSDP variable.
public struct MSDPVariableState {
    public var value: String
    public var flags: MSDPFlags

    public init(value: String = "", flags: MSDPFlags = []) {
        self.value = value
        self.flags = flags
    }
}

/// The default MSDP variable table matching the C `msdp_table[]`.
/// Alphabetically sorted as required by the MSDP specification.
public let defaultMSDPTable: [MSDPVariableDefinition] = [
    MSDPVariableDefinition(name: "ALIGNMENT",              flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "ARACHNOS_DEVEL",         flags: [.configurable, .reportable]),
    MSDPVariableDefinition(name: "ARACHNOS_MUDLIST",       flags: [.configurable]),
    MSDPVariableDefinition(name: "COMMANDS",               flags: [.command, .list]),
    MSDPVariableDefinition(name: "CONFIGURABLE_VARIABLES", flags: [.configurable, .list]),
    MSDPVariableDefinition(name: "EXPERIENCE",             flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "EXPERIENCE_MAX",         flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "HEALTH",                 flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "HEALTH_MAX",             flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "LEVEL",                  flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "LIST",                   flags: [.command]),
    MSDPVariableDefinition(name: "LISTS",                  flags: [.list]),
    MSDPVariableDefinition(name: "MANA",                   flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "MANA_MAX",               flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "MONEY",                  flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "MOVEMENT",               flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "MOVEMENT_MAX",           flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "REPORT",                 flags: [.command]),
    MSDPVariableDefinition(name: "REPORTABLE_VARIABLES",   flags: [.reportable, .list]),
    MSDPVariableDefinition(name: "REPORTED_VARIABLES",     flags: [.reported, .list]),
    MSDPVariableDefinition(name: "RESET",                  flags: [.command]),
    MSDPVariableDefinition(name: "ROOM",                   flags: [.reportable]),
    MSDPVariableDefinition(name: "ROOM_EXITS",             flags: [.sendable, .reportable]),
    MSDPVariableDefinition(name: "SEND",                   flags: [.command]),
    MSDPVariableDefinition(name: "SENDABLE_VARIABLES",     flags: [.sendable, .list]),
    MSDPVariableDefinition(name: "SPECIFICATION",          flags: [.sendable]),
    MSDPVariableDefinition(name: "UNREPORT",               flags: [.command]),
]
