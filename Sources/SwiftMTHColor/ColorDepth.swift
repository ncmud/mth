/// The color depth supported by the client terminal.
public enum ColorDepth: Int {
    /// No colors — strip all color codes.
    case none = 0
    /// 16-color ANSI.
    case ansi16 = 16
    /// xterm 256 colors.
    case xterm256 = 256
    /// True color (24-bit RGB via 4096-color mapping).
    case trueColor = 4096
}
