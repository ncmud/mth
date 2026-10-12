package mth.core

/** Client reports are informational, including the claimed IP address. */
data class MNESEnvironment(
    val clientName: String? = null, val clientVersion: String? = null,
    val charset: String? = null, val ipAddress: String? = null,
    val mtts: Int? = null, val terminalType: String? = null
) {
    val variables: Map<String, String> get() = listOf(
        "CLIENT_NAME" to clientName, "CLIENT_VERSION" to clientVersion,
        "CHARSET" to charset, "IPADDRESS" to ipAddress,
        "MTTS" to mtts?.toString(), "TERMINAL_TYPE" to terminalType
    ).mapNotNull { (name, value) -> value?.let { name to it } }.toMap()

    fun apply(entries: List<NewEnviron.Entry>): MNESEnvironment {
        var result = this
        for (entry in entries) {
            val raw = entry.value
            if (raw != null && (raw.toByteArray().size > 256 || raw.any { it.isISOControl() })) continue
            val value = raw?.takeIf { it.isNotEmpty() }
            result = when (entry.name) {
                "CLIENT_NAME" -> result.copy(clientName = value)
                "CLIENT_VERSION" -> result.copy(clientVersion = value)
                "CHARSET" -> result.copy(charset = value?.uppercase())
                "TERMINAL_TYPE" -> result.copy(terminalType = value)
                "IPADDRESS" -> if (value == null || isIPAddress(value)) result.copy(ipAddress = value) else result
                "MTTS" -> if (value == null) result.copy(mtts = null)
                    else if (value.all { it in '0'..'9' } && value.toIntOrNull() != null) result.copy(mtts = value.toInt()) else result
                else -> result
            }
        }
        return result
    }
    val validated: MNESEnvironment get() = MNESEnvironment().apply(variables.map { NewEnviron.Entry(it.key, it.value) })

    companion object {
        val variableNames = listOf("IPADDRESS", "CLIENT_NAME", "CLIENT_VERSION", "CHARSET", "MTTS", "TERMINAL_TYPE")
        fun isIPAddress(value: String): Boolean {
            fun ipv4(text: String): Boolean {
                val parts = text.split('.')
                return parts.size == 4 && parts.all {
                    it.isNotEmpty() && it.length <= 3 && (it.length == 1 || it.first() != '0') &&
                        it.all { c -> c in '0'..'9' } && (it.toIntOrNull() ?: 256) <= 255
                }
            }
            if (!value.contains(':')) return ipv4(value)
            val halves = value.split("::")
            if (halves.size > 2) return false
            val parts = value.split(':').filter { it.isNotEmpty() }
            var groups = 0
            for ((index, part) in parts.withIndex()) {
                if (part.contains('.')) {
                    if (index != parts.lastIndex || !value.endsWith(part) || !ipv4(part)) return false
                    groups += 2
                } else {
                    if (part.length > 4 || !part.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return false
                    groups++
                }
            }
            return if (halves.size == 2) groups < 8 && halves.all { !it.startsWith(':') && !it.endsWith(':') }
                else groups == 8 && !value.startsWith(':') && !value.endsWith(':')
        }
    }
}

object NewEnviron {
    data class Entry(val name: String, val value: String? = null, val userDefined: Boolean = false)
    data class Message(val command: Byte, val entries: List<Entry>)
    fun frameLength(bytes: ByteArray, offset: Int): Int? {
        var i = offset + 3
        while (i + 1 < bytes.size) {
            if (bytes[i] == TelnetCommand.IAC) {
                if (bytes[i + 1] == TelnetCommand.SE) return i + 2 - offset
                i += 2
            } else i++
        }
        return null
    }
    fun decode(frame: ByteArray): Message? {
        if (frame.size !in 6..8192 || !frame.take(3).toByteArray().contentEquals(byteArrayOf(-1, -6, 39)) ||
            !frame.takeLast(2).toByteArray().contentEquals(byteArrayOf(-1, -16)) || frame[3].toInt() !in 0..2) return null
        val payload = mutableListOf<Byte>()
        var i = 4
        while (i < frame.size - 2) {
            val byte = frame[i]
            if (byte == TelnetCommand.IAC) {
                if (i + 1 >= frame.size - 2 || frame[i + 1] != TelnetCommand.IAC) return null
                i++
            }
            payload.add(byte); i++
        }
        val entries = mutableListOf<Entry>()
        var name: MutableList<Byte>? = null
        var value: MutableList<Byte>? = null
        var userDefined = false
        fun finish(): Boolean {
            val key = name ?: return true
            if (key.size > 64) return false
            try {
                entries.add(Entry(key.toByteArray().decodeToString(throwOnInvalidSequence = true),
                    value?.toByteArray()?.decodeToString(throwOnInvalidSequence = true), userDefined))
            } catch (_: CharacterCodingException) { return false }
            return entries.size <= 64
        }
        i = 0
        while (i < payload.size) {
            val byte = payload[i]
            when (byte.toInt()) {
                0, 3 -> { if (!finish()) return null; name = mutableListOf(); value = null; userDefined = byte.toInt() == 3 }
                1 -> { if (name == null || value != null) return null; value = mutableListOf() }
                2 -> {
                    i++
                    if (i >= payload.size || name == null) return null
                    (value ?: name)!!.add(payload[i])
                }
                else -> { if (name == null) return null; (value ?: name)!!.add(byte) }
            }
            i++
        }
        if (!finish()) return null
        return Message(frame[3], entries)
    }
    fun packet(command: Byte, entries: List<Entry>): ByteArray {
        val result = mutableListOf<Byte>(-1, -6, 39, command)
        fun append(text: String) {
            for (byte in text.toByteArray()) {
                if (byte.toInt() in 0..3) result.add(2)
                if (byte == TelnetCommand.IAC) result.add(byte)
                result.add(byte)
            }
        }
        for (entry in entries) {
            result.add(if (entry.userDefined) 3 else 0); append(entry.name)
            entry.value?.let { result.add(1); append(it) }
        }
        result.add(-1); result.add(-16)
        return result.toByteArray()
    }
}
