package mth.core

@JvmInline
value class MSDPFlags(val rawValue: Int = 0) {
    operator fun contains(flag: MSDPFlags): Boolean = rawValue and flag.rawValue == flag.rawValue
    fun insert(flag: MSDPFlags) = MSDPFlags(rawValue or flag.rawValue)
    fun remove(flag: MSDPFlags) = MSDPFlags(rawValue and flag.rawValue.inv())
    fun subtract(flag: MSDPFlags) = MSDPFlags(rawValue and flag.rawValue.inv())
    fun isEmpty(): Boolean = rawValue == 0

    companion object {
        val COMMAND = MSDPFlags(1 shl 0)
        val LIST = MSDPFlags(1 shl 1)
        val SENDABLE = MSDPFlags(1 shl 2)
        val REPORTABLE = MSDPFlags(1 shl 3)
        val CONFIGURABLE = MSDPFlags(1 shl 4)
        val REPORTED = MSDPFlags(1 shl 5)
        val UPDATED = MSDPFlags(1 shl 6)

        infix fun Int.or(flag: MSDPFlags) = this or flag.rawValue
        fun of(a: MSDPFlags, b: MSDPFlags) = MSDPFlags(a.rawValue or b.rawValue)
    }
}

data class MSDPVariableDefinition(
    val name: String,
    val flags: MSDPFlags
)

class MSDPVariableState(
    var value: String = "",
    var flags: MSDPFlags = MSDPFlags()
)

val defaultMSDPTable: List<MSDPVariableDefinition> = listOf(
    MSDPVariableDefinition("ALIGNMENT", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("ARACHNOS_DEVEL", MSDPFlags.of(MSDPFlags.CONFIGURABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("ARACHNOS_MUDLIST", MSDPFlags(MSDPFlags.CONFIGURABLE.rawValue)),
    MSDPVariableDefinition("COMMANDS", MSDPFlags.of(MSDPFlags.COMMAND, MSDPFlags.LIST)),
    MSDPVariableDefinition("CONFIGURABLE_VARIABLES", MSDPFlags.of(MSDPFlags.CONFIGURABLE, MSDPFlags.LIST)),
    MSDPVariableDefinition("EXPERIENCE", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("EXPERIENCE_MAX", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("HEALTH", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("HEALTH_MAX", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("LEVEL", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("LIST", MSDPFlags(MSDPFlags.COMMAND.rawValue)),
    MSDPVariableDefinition("LISTS", MSDPFlags(MSDPFlags.LIST.rawValue)),
    MSDPVariableDefinition("MANA", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("MANA_MAX", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("MONEY", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("MOVEMENT", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("MOVEMENT_MAX", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("REPORT", MSDPFlags(MSDPFlags.COMMAND.rawValue)),
    MSDPVariableDefinition("REPORTABLE_VARIABLES", MSDPFlags.of(MSDPFlags.REPORTABLE, MSDPFlags.LIST)),
    MSDPVariableDefinition("REPORTED_VARIABLES", MSDPFlags.of(MSDPFlags.REPORTED, MSDPFlags.LIST)),
    MSDPVariableDefinition("RESET", MSDPFlags(MSDPFlags.COMMAND.rawValue)),
    MSDPVariableDefinition("ROOM", MSDPFlags(MSDPFlags.REPORTABLE.rawValue)),
    MSDPVariableDefinition("ROOM_EXITS", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.REPORTABLE)),
    MSDPVariableDefinition("SEND", MSDPFlags(MSDPFlags.COMMAND.rawValue)),
    MSDPVariableDefinition("SENDABLE_VARIABLES", MSDPFlags.of(MSDPFlags.SENDABLE, MSDPFlags.LIST)),
    MSDPVariableDefinition("SPECIFICATION", MSDPFlags(MSDPFlags.SENDABLE.rawValue)),
    MSDPVariableDefinition("UNREPORT", MSDPFlags(MSDPFlags.COMMAND.rawValue)),
)
