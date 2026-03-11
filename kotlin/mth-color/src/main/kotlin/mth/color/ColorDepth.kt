package mth.color

enum class ColorDepth(val colors: Int) {
    NONE(0),
    ANSI16(16),
    XTERM256(256),
    TRUE_COLOR(4096)
}
