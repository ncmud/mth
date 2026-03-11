package mth.core

/**
 * Manages MSDP variable state for a single connection.
 *
 * Replaces the C per-connection `msdp_data` array and the global `msdp_table`
 * functions. Each MSDPManager instance corresponds to one telnet session.
 */
class MSDPManager(
    table: List<MSDPVariableDefinition> = defaultMSDPTable,
    val writeHandler: (ByteArray) -> Unit,
    val logHandler: (String) -> Unit = {}
) {
    // MSDP protocol control bytes
    companion object {
        private const val MSDP_VAR: Byte = 1
        private const val MSDP_VAL: Byte = 2
        private const val MSDP_TABLE_OPEN: Byte = 3
        private const val MSDP_TABLE_CLOSE: Byte = 4
        private const val MSDP_ARRAY_OPEN: Byte = 5
        private const val MSDP_ARRAY_CLOSE: Byte = 6
        private val IAC: Byte = 0xFF.toByte()
        private val SB: Byte = 0xFA.toByte()
        private val SE: Byte = 0xF0.toByte()
        private const val TELOPT_MSDP: Byte = 69
    }

    /** Variable definitions (shared, immutable). */
    private val definitions: List<MSDPVariableDefinition> = table

    /** Fast lookup from variable name to index in definitions. */
    private val nameIndex: Map<String, Int> = buildMap {
        for ((i, def) in table.withIndex()) {
            put(def.name, i)
        }
    }

    /** Per-connection variable state, indexed by position in definitions. */
    private val state: MutableList<MSDPVariableState> = table.map { def ->
        MSDPVariableState(value = "", flags = def.flags)
    }.toMutableList()

    /** Whether any variable needs to be flushed via flushUpdates(). */
    var needsUpdate: Boolean = false
        private set

    /** Whether this connection uses GMCP (JSON) instead of raw MSDP. */
    var usesGMCP: Boolean = false

    // -- Variable Lookup --

    private fun findIndex(name: String): Int? = nameIndex[name]

    // -- Copyover Support --

    /** Names of variables currently marked as reported (for copyover snapshot). */
    val reportedVariableNames: List<String>
        get() {
            val names = mutableListOf<String>()
            for (idx in definitions.indices) {
                if (MSDPFlags.REPORTED in state[idx].flags) {
                    names.add(definitions[idx].name)
                }
            }
            return names
        }

    /** Restore reported variable flags from a list of variable names (after copyover). */
    fun restoreReportedVariables(names: List<String>) {
        for (name in names) {
            val idx = findIndex(name) ?: continue
            state[idx].flags = state[idx].flags.insert(MSDPFlags.REPORTED)
        }
    }

    // -- Reading --

    /** Get the current value of a variable, or null if unknown. */
    fun getVariable(name: String): String? {
        val idx = findIndex(name)
        if (idx == null) {
            logHandler("msdp_get_var: Unknown variable: $name.")
            return null
        }
        return state[idx].value
    }

    // -- Updating --

    /**
     * Update a variable's value. If the variable is being reported and the
     * value changed, queues it for the next flushUpdates() call.
     */
    fun updateVariable(name: String, value: String) {
        val idx = findIndex(name)
        if (idx == null) {
            logHandler("msdp_update_var: Unknown variable: $name.")
            return
        }

        if (state[idx].value != value) {
            if (MSDPFlags.REPORTED in state[idx].flags) {
                state[idx].flags = state[idx].flags.insert(MSDPFlags.UPDATED)
                needsUpdate = true
            }
            state[idx].value = value
        }
    }

    /**
     * Update a variable's value and immediately send it if reported.
     */
    fun updateVariableImmediate(name: String, value: String) {
        val idx = findIndex(name)
        if (idx == null) {
            logHandler("msdp_update_var_instant: Unknown variable: $name.")
            return
        }

        if (state[idx].value != value) {
            state[idx].value = value
        }

        if (MSDPFlags.REPORTED in state[idx].flags) {
            val packet = mutableListOf<Byte>()
            packet.add(IAC)
            packet.add(SB)
            packet.add(TELOPT_MSDP)
            packet.add(MSDP_VAR)
            packet.addAll(definitions[idx].name.toByteArray(Charsets.UTF_8).toList())
            packet.add(MSDP_VAL)
            packet.addAll(value.toByteArray(Charsets.UTF_8).toList())
            packet.add(IAC)
            packet.add(SE)
            writeMSDP(packet.toByteArray())
        }
    }

    /**
     * Send all reported variables that have been updated since the last flush.
     */
    fun flushUpdates() {
        val packet = mutableListOf<Byte>()
        packet.add(IAC)
        packet.add(SB)
        packet.add(TELOPT_MSDP)
        var hasContent = false

        for (idx in definitions.indices) {
            if (MSDPFlags.UPDATED in state[idx].flags) {
                packet.add(MSDP_VAR)
                packet.addAll(definitions[idx].name.toByteArray(Charsets.UTF_8).toList())
                packet.add(MSDP_VAL)
                packet.addAll(state[idx].value.toByteArray(Charsets.UTF_8).toList())
                state[idx].flags = state[idx].flags.remove(MSDPFlags.UPDATED)
                hasContent = true
            }
        }

        packet.add(IAC)
        packet.add(SE)

        if (hasContent) {
            writeMSDP(packet.toByteArray())
        }

        needsUpdate = false
    }

    // -- Client Commands --

    /**
     * Process an incoming MSDP variable/value pair from the client.
     */
    fun processVarVal(variable: String, value: String) {
        val varIdx = findIndex(variable) ?: return
        val def = definitions[varIdx]

        if (MSDPFlags.CONFIGURABLE in def.flags) {
            state[varIdx].value = value
            handleCommand(varIdx)
            return
        }

        if (MSDPFlags.COMMAND in def.flags) {
            if (value.isNotEmpty() && value.toByteArray(Charsets.UTF_8)[0] == MSDP_ARRAY_OPEN) {
                processArray(varIdx, value)
            } else {
                val valIdx = findIndex(value) ?: return
                handleCommandWithArgument(varIdx, valIdx)
            }
        }
    }

    /** Process a 1D array argument for a command variable. */
    private fun processArray(varIdx: Int, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        var i = 0
        val buf = mutableListOf<Byte>()

        while (i < bytes.size) {
            when (bytes[i]) {
                MSDP_ARRAY_OPEN -> {
                    i++
                }
                MSDP_VAL -> {
                    if (buf.isNotEmpty()) {
                        val name = String(buf.toByteArray(), Charsets.UTF_8)
                        val argIdx = findIndex(name)
                        if (argIdx != null) {
                            handleCommandWithArgument(varIdx, argIdx)
                        }
                    }
                    buf.clear()
                    i++
                }
                MSDP_ARRAY_CLOSE -> {
                    if (buf.isNotEmpty()) {
                        val name = String(buf.toByteArray(), Charsets.UTF_8)
                        val argIdx = findIndex(name)
                        if (argIdx != null) {
                            handleCommandWithArgument(varIdx, argIdx)
                        }
                    }
                    return
                }
                else -> {
                    buf.add(bytes[i])
                    i++
                }
            }
        }

        if (buf.isNotEmpty()) {
            val name = String(buf.toByteArray(), Charsets.UTF_8)
            val argIdx = findIndex(name)
            if (argIdx != null) {
                handleCommandWithArgument(varIdx, argIdx)
            }
        }
    }

    /** Dispatch a command with no argument (configurable variable handler). */
    private fun handleCommand(varIdx: Int) {
        @Suppress("UNUSED_VARIABLE")
        val name = definitions[varIdx].name
        // Arachnos handlers are MUD-specific; delegate up
    }

    /** Dispatch a command with a variable-index argument. */
    private fun handleCommandWithArgument(cmdIdx: Int, argumentIndex: Int) {
        when (definitions[cmdIdx].name) {
            "LIST" -> commandList(argumentIndex)
            "REPORT" -> commandReport(argumentIndex)
            "UNREPORT" -> commandUnreport(argumentIndex)
            "SEND" -> commandSend(argumentIndex)
            "RESET" -> commandReset(argumentIndex)
        }
    }

    // -- Command Implementations --

    /** LIST command: send a list of variables matching the requested category. */
    private fun commandList(index: Int) {
        val def = definitions[index]
        if (MSDPFlags.LIST !in def.flags) return

        val packet = mutableListOf<Byte>()
        packet.add(IAC)
        packet.add(SB)
        packet.add(TELOPT_MSDP)
        packet.add(MSDP_VAR)
        packet.addAll(def.name.toByteArray(Charsets.UTF_8).toList())
        packet.add(MSDP_VAL)
        packet.add(MSDP_ARRAY_OPEN)

        val flag = def.flags.subtract(MSDPFlags.LIST)

        for (idx in definitions.indices) {
            if (!flag.isEmpty()) {
                // List variables matching the flag (excluding other list vars)
                if (flag in state[idx].flags && MSDPFlags.LIST !in state[idx].flags) {
                    packet.add(MSDP_VAL)
                    packet.addAll(definitions[idx].name.toByteArray(Charsets.UTF_8).toList())
                }
            } else {
                // flag is empty after removing .list -> this is "LISTS", list all list variables
                if (MSDPFlags.LIST in state[idx].flags) {
                    packet.add(MSDP_VAL)
                    packet.addAll(definitions[idx].name.toByteArray(Charsets.UTF_8).toList())
                }
            }
        }

        packet.add(MSDP_ARRAY_CLOSE)
        packet.add(IAC)
        packet.add(SE)

        writeMSDP(packet.toByteArray())
    }

    /** REPORT command: enable auto-reporting for a variable. */
    private fun commandReport(index: Int) {
        if (MSDPFlags.REPORTABLE !in definitions[index].flags) return

        state[index].flags = state[index].flags.insert(MSDPFlags.REPORTED)

        if (MSDPFlags.SENDABLE !in definitions[index].flags) return

        state[index].flags = state[index].flags.insert(MSDPFlags.UPDATED)
        needsUpdate = true
    }

    /** UNREPORT command: disable auto-reporting for a variable. */
    private fun commandUnreport(index: Int) {
        if (MSDPFlags.REPORTABLE !in definitions[index].flags) return
        state[index].flags = state[index].flags.remove(MSDPFlags.REPORTED)
    }

    /** SEND command: queue a sendable variable for immediate update. */
    private fun commandSend(index: Int) {
        if (MSDPFlags.SENDABLE in state[index].flags) {
            state[index].flags = state[index].flags.insert(MSDPFlags.UPDATED)
            needsUpdate = true
        }
    }

    /** RESET command: reset all variables matching the list's flag. */
    private fun commandReset(index: Int) {
        if (MSDPFlags.LIST !in definitions[index].flags) return

        val flag = definitions[index].flags.subtract(MSDPFlags.LIST)

        for (idx in definitions.indices) {
            if (flag in state[idx].flags) {
                state[idx].flags = definitions[idx].flags
            }
        }
    }

    // -- Output --

    /** Write an MSDP packet, converting to GMCP JSON if needed. */
    private fun writeMSDP(packet: ByteArray) {
        if (usesGMCP) {
            val json = msdp2json(packet)
            writeHandler(json)
        } else {
            writeHandler(packet)
        }
    }
}
