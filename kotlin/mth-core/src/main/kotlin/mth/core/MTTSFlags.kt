package mth.core

@JvmInline
value class MTTSFlags(val rawValue: Int = 0) {
    operator fun contains(flag: MTTSFlags): Boolean = rawValue and flag.rawValue == flag.rawValue

    companion object {
        val ANSI = MTTSFlags(1 shl 0)
        val VT100 = MTTSFlags(1 shl 1)
        val UTF8 = MTTSFlags(1 shl 2)
        val COLORS_256 = MTTSFlags(1 shl 3)
        val MOUSE_TRACKING = MTTSFlags(1 shl 4)
        val COLOR_PALETTE = MTTSFlags(1 shl 5)
        val SCREEN_READER = MTTSFlags(1 shl 6)
        val PROXY = MTTSFlags(1 shl 7)
        val TRUE_COLOR = MTTSFlags(1 shl 8)
    }
}
