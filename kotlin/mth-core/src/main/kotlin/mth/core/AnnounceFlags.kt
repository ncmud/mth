package mth.core

@JvmInline
value class AnnounceFlags(val rawValue: Int) {
    operator fun contains(other: AnnounceFlags): Boolean = rawValue and other.rawValue == other.rawValue
    fun isEmpty(): Boolean = rawValue == 0
    infix fun or(other: AnnounceFlags) = AnnounceFlags(rawValue or other.rawValue)

    companion object {
        val NONE = AnnounceFlags(0)
        val WILL = AnnounceFlags(1 shl 0)
        val DO = AnnounceFlags(1 shl 1)
    }
}

data class TelnetOptionEntry(
    val name: String,
    val announce: AnnounceFlags = AnnounceFlags.NONE
)

val defaultTelnetTable: List<TelnetOptionEntry> = buildList {
    repeat(256) { add(TelnetOptionEntry("")) }
    this[1] = TelnetOptionEntry("ECHO")
    this[3] = TelnetOptionEntry("SUPPRESS GA")
    this[24] = TelnetOptionEntry("TERMINAL TYPE", AnnounceFlags.DO)
    this[25] = TelnetOptionEntry("EOR")
    this[31] = TelnetOptionEntry("NAWS", AnnounceFlags.DO)
    this[39] = TelnetOptionEntry("NEW_ENVIRON", AnnounceFlags.DO)
    this[42] = TelnetOptionEntry("CHARSET", AnnounceFlags.WILL)
    this[69] = TelnetOptionEntry("MSDP", AnnounceFlags.WILL)
    this[70] = TelnetOptionEntry("MSSP", AnnounceFlags.WILL)
    this[86] = TelnetOptionEntry("MCCP2", AnnounceFlags.WILL)
    this[87] = TelnetOptionEntry("MCCP3", AnnounceFlags.WILL)
    this[90] = TelnetOptionEntry("MSP", AnnounceFlags.WILL)
    this[91] = TelnetOptionEntry("MXP")
    this[201] = TelnetOptionEntry("GMCP", AnnounceFlags.WILL)
}
