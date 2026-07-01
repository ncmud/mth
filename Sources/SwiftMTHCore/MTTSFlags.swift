/// MTTS (Mud Terminal Type Standard) capability flags.
///
/// Reported by the client via terminal type subnegotiation
/// in the format "MTTS <bitmask>".
public struct MTTSFlags: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let ansi           = MTTSFlags(rawValue: 1 << 0)
    public static let vt100          = MTTSFlags(rawValue: 1 << 1)
    public static let utf8           = MTTSFlags(rawValue: 1 << 2)
    public static let colors256      = MTTSFlags(rawValue: 1 << 3)
    public static let mouseTracking  = MTTSFlags(rawValue: 1 << 4)
    public static let colorPalette   = MTTSFlags(rawValue: 1 << 5)
    public static let screenReader   = MTTSFlags(rawValue: 1 << 6)
    public static let proxy          = MTTSFlags(rawValue: 1 << 7)
    public static let trueColor      = MTTSFlags(rawValue: 1 << 8)
    public static let mnes           = MTTSFlags(rawValue: 1 << 9)
    public static let mslp           = MTTSFlags(rawValue: 1 << 10)
    public static let ssl            = MTTSFlags(rawValue: 1 << 11)
}
