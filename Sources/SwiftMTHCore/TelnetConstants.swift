// MARK: - Telnet Protocol Constants

/// Telnet command bytes.
public enum TelnetCommand {
    public static let IAC: UInt8   = 255
    public static let DONT: UInt8  = 254
    public static let DO: UInt8    = 253
    public static let WONT: UInt8  = 252
    public static let WILL: UInt8  = 251
    public static let SB: UInt8    = 250
    public static let GA: UInt8    = 249
    public static let EL: UInt8    = 248
    public static let EC: UInt8    = 247
    public static let AYT: UInt8   = 246
    public static let AO: UInt8    = 245
    public static let IP: UInt8    = 244
    public static let BREAK: UInt8 = 243
    public static let DM: UInt8    = 242
    public static let NOP: UInt8   = 241
    public static let SE: UInt8    = 240
    public static let EOR: UInt8   = 239
    public static let ABORT: UInt8 = 238
    public static let SUSP: UInt8  = 237
    public static let xEOF: UInt8  = 236

    /// True if `c` is a valid telnet command (>= xEOF).
    public static func isCommand(_ c: UInt8) -> Bool {
        c >= xEOF
    }
}

/// Telnet option numbers.
public enum TelnetOption {
    public static let ECHO: UInt8         = 1
    public static let SGA: UInt8          = 3
    public static let TTYPE: UInt8        = 24
    public static let EOR: UInt8          = 25
    public static let NAWS: UInt8         = 31
    public static let NEW_ENVIRON: UInt8  = 39
    public static let CHARSET: UInt8      = 42
    public static let MSDP: UInt8         = 69
    public static let MSSP: UInt8         = 70
    public static let MCCP2: UInt8        = 86
    public static let MCCP3: UInt8        = 87
    public static let MSP: UInt8          = 90
    public static let MXP: UInt8          = 91
    public static let GMCP: UInt8         = 201
}

/// Sub-constants used within subnegotiations.
public enum TelnetSub {
    // NEW-ENVIRON
    public static let ENV_IS: UInt8   = 0
    public static let ENV_SEND: UInt8 = 1
    public static let ENV_INFO: UInt8 = 2
    public static let ENV_VAR: UInt8  = 0
    public static let ENV_VAL: UInt8  = 1
    public static let ENV_ESC: UInt8  = 2
    public static let ENV_USR: UInt8  = 3

    // CHARSET
    public static let CHARSET_REQUEST: UInt8  = 1
    public static let CHARSET_ACCEPTED: UInt8 = 2
    public static let CHARSET_REJECTED: UInt8 = 3

    // MSSP
    public static let MSSP_VAR: UInt8 = 1
    public static let MSSP_VAL: UInt8 = 2
}

/// Announcement flags for the telnet option table.
public struct AnnounceFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let will = AnnounceFlags(rawValue: 1 << 0)
    public static let `do`   = AnnounceFlags(rawValue: 1 << 1)
}

/// Entry in the telnet option announcement table.
/// Determines which options are announced on connection.
public struct TelnetOptionEntry: Sendable {
    public let name: String
    public let announce: AnnounceFlags

    public init(_ name: String, _ announce: AnnounceFlags = []) {
        self.name = name
        self.announce = announce
    }
}

/// Default telnet option announcement table.
/// Index by telnet option number (0-255). Options with non-empty announce
/// flags will be sent as WILL/DO on connection.
public let defaultTelnetTable: [TelnetOptionEntry] = {
    var table = [TelnetOptionEntry](repeating: TelnetOptionEntry("", []), count: 256)

    table[1]   = TelnetOptionEntry("ECHO")
    table[3]   = TelnetOptionEntry("SUPPRESS GA")
    table[24]  = TelnetOptionEntry("TERMINAL TYPE", .do)
    table[25]  = TelnetOptionEntry("EOR")
    table[31]  = TelnetOptionEntry("NAWS", .do)
    table[39]  = TelnetOptionEntry("NEW_ENVIRON", .do)
    table[42]  = TelnetOptionEntry("CHARSET", .will)
    table[69]  = TelnetOptionEntry("MSDP", .will)
    table[70]  = TelnetOptionEntry("MSSP", .will)
    table[86]  = TelnetOptionEntry("MCCP2", .will)
    table[87]  = TelnetOptionEntry("MCCP3", .will)
    table[90]  = TelnetOptionEntry("MSP", .will)
    table[91]  = TelnetOptionEntry("MXP")
    table[201] = TelnetOptionEntry("GMCP", .will)

    return table
}()
