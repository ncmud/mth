package mth.core

@JvmInline
value class CommFlags(val rawValue: Int = 0) {
    operator fun contains(flag: CommFlags): Boolean = rawValue and flag.rawValue == flag.rawValue
    fun insert(flag: CommFlags) = CommFlags(rawValue or flag.rawValue)
    fun remove(flag: CommFlags) = CommFlags(rawValue and flag.rawValue.inv())
    fun isEmpty(): Boolean = rawValue == 0

    companion object {
        val DISCONNECT = CommFlags(1 shl 0)
        val PASSWORD = CommFlags(1 shl 1)
        val REMOTE_ECHO = CommFlags(1 shl 2)
        val EOR = CommFlags(1 shl 3)
        val MSDP_UPDATE = CommFlags(1 shl 4)
        val COLORS_256 = CommFlags(1 shl 5)
        val UTF8 = CommFlags(1 shl 6)
        val GMCP = CommFlags(1 shl 7)
    }
}
