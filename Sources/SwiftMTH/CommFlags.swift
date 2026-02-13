/// Communication flags for a telnet session.
///
/// Tracks negotiated protocol features and connection state.
public struct CommFlags: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let disconnect  = CommFlags(rawValue: 1 << 0)
    public static let password    = CommFlags(rawValue: 1 << 1)
    public static let remoteEcho  = CommFlags(rawValue: 1 << 2)
    public static let eor         = CommFlags(rawValue: 1 << 3)
    public static let msdpUpdate  = CommFlags(rawValue: 1 << 4)
    public static let colors256   = CommFlags(rawValue: 1 << 5)
    public static let utf8        = CommFlags(rawValue: 1 << 6)
    public static let gmcp        = CommFlags(rawValue: 1 << 7)
}
