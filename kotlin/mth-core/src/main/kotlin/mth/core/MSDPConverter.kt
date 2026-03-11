package mth.core

// MSDP protocol control bytes
private const val MSDP_VAR: Byte = 1
private const val MSDP_VAL: Byte = 2
private const val MSDP_TABLE_OPEN: Byte = 3
private const val MSDP_TABLE_CLOSE: Byte = 4
private const val MSDP_ARRAY_OPEN: Byte = 5
private const val MSDP_ARRAY_CLOSE: Byte = 6

// Telnet framing bytes
private const val IAC: Byte = 0xFF.toByte()  // -1 signed
private const val SB: Byte = 0xFA.toByte()   // -6 signed
private const val SE: Byte = 0xF0.toByte()   // -16 signed
private const val TELOPT_MSDP: Byte = 69
private const val TELOPT_GMCP: Byte = 0xC9.toByte() // 201 / -55 signed

/** Extension to get unsigned int value of a Byte. */
private val Byte.u: Int get() = toInt() and 0xFF

/**
 * Convert MSDP binary subnegotiation to GMCP JSON subnegotiation.
 *
 * Input: `IAC SB TELOPT_MSDP <msdp data> IAC SE`
 * Output: `IAC SB TELOPT_GMCP MSDP {<json>} IAC SE`
 */
fun msdp2json(src: ByteArray): ByteArray {
    val out = mutableListOf<Byte>()
    val srclen = src.size

    // If MSDP framing, replace with GMCP framing + "MSDP {"
    if (srclen >= 3 && src[2] == TELOPT_MSDP) {
        out.add(IAC)
        out.add(SB)
        out.add(TELOPT_GMCP)
        for (b in "MSDP {".toByteArray(Charsets.UTF_8)) {
            out.add(b)
        }
    }

    var i = 3
    var nest = 0
    var last: Byte = 0

    while (i < srclen) {
        if (src[i] == IAC && i + 1 < srclen && src[i + 1] == SE) {
            break
        }

        when (src[i]) {
            MSDP_TABLE_OPEN -> {
                out.add('{'.code.toByte())
                nest++
                last = MSDP_TABLE_OPEN
            }
            MSDP_TABLE_CLOSE -> {
                if (last == MSDP_VAL || last == MSDP_VAR) {
                    out.add('"'.code.toByte())
                }
                if (nest > 0) nest--
                out.add('}'.code.toByte())
                last = MSDP_TABLE_CLOSE
            }
            MSDP_ARRAY_OPEN -> {
                out.add('['.code.toByte())
                nest++
                last = MSDP_ARRAY_OPEN
            }
            MSDP_ARRAY_CLOSE -> {
                if (last == MSDP_VAL || last == MSDP_VAR) {
                    out.add('"'.code.toByte())
                }
                if (nest > 0) nest--
                out.add(']'.code.toByte())
                last = MSDP_ARRAY_CLOSE
            }
            MSDP_VAR -> {
                if (last == MSDP_VAL || last == MSDP_VAR) {
                    out.add('"'.code.toByte())
                }
                if (last == MSDP_VAL || last == MSDP_VAR || last == MSDP_TABLE_CLOSE || last == MSDP_ARRAY_CLOSE) {
                    out.add(','.code.toByte())
                }
                out.add('"'.code.toByte())
                last = MSDP_VAR
            }
            MSDP_VAL -> {
                if (last == MSDP_VAR) {
                    out.add('"'.code.toByte())
                    out.add(':'.code.toByte())
                }
                if (last == MSDP_VAL) {
                    out.add('"'.code.toByte())
                    out.add(','.code.toByte())
                }
                if (i + 1 < srclen && src[i + 1] != MSDP_TABLE_OPEN && src[i + 1] != MSDP_ARRAY_OPEN) {
                    out.add('"'.code.toByte())
                }
                last = MSDP_VAL
            }
            '\\'.code.toByte() -> {
                out.add('\\'.code.toByte())
                out.add('\\'.code.toByte())
            }
            '"'.code.toByte() -> {
                out.add('\\'.code.toByte())
                out.add('"'.code.toByte())
            }
            else -> {
                out.add(src[i])
            }
        }
        i++
    }

    // Append closing "}" and IAC SE
    out.add('}'.code.toByte())
    out.add(IAC)
    out.add(SE)

    return out.toByteArray()
}

/**
 * Convert GMCP JSON subnegotiation to MSDP binary subnegotiation.
 *
 * Input: `IAC SB TELOPT_GMCP MSDP {<json>} IAC SE`
 * Output: `IAC SB TELOPT_MSDP <msdp data> IAC SE`
 */
fun json2msdp(src: ByteArray): ByteArray {
    val out = mutableListOf<Byte>()
    val srclen = src.size

    // If GMCP framing, replace with MSDP framing
    if (srclen >= 3 && src[2] == TELOPT_GMCP) {
        out.add(IAC)
        out.add(SB)
        out.add(TELOPT_MSDP)
    }

    var i = 3

    // Skip "MSDP {" prefix if present
    if (i + 6 <= srclen) {
        val prefix = "MSDP {".toByteArray(Charsets.UTF_8)
        var matches = true
        for (k in prefix.indices) {
            if (src[i + k] != prefix[k]) {
                matches = false
                break
            }
        }
        if (matches) {
            i += 6
        }
    }

    val state = IntArray(100)
    var nest = 0
    var last: Byte = 0
    state[0] = 0

    while (i < srclen && src[i] != IAC && nest < 99) {
        when (src[i]) {
            ' '.code.toByte() -> {
                i++
            }
            '{'.code.toByte() -> {
                out.add(MSDP_TABLE_OPEN)
                i++
                nest++
                state[nest] = 0
            }
            '}'.code.toByte() -> {
                nest--
                i++
                if (nest < 0) {
                    out.add(IAC)
                    out.add(SE)
                    return out.toByteArray()
                }
                out.add(MSDP_TABLE_CLOSE)
            }
            '['.code.toByte() -> {
                i++
                nest++
                state[nest] = 1
                out.add(MSDP_ARRAY_OPEN)
            }
            ']'.code.toByte() -> {
                nest--
                i++
                out.add(MSDP_ARRAY_CLOSE)
            }
            ':'.code.toByte() -> {
                out.add(MSDP_VAL)
                i++
            }
            ','.code.toByte() -> {
                i++
                if (state[nest] != 0) {
                    out.add(MSDP_VAL)
                } else {
                    out.add(MSDP_VAR)
                }
            }
            '"'.code.toByte() -> {
                i++
                if (last == 0.toByte()) {
                    last = MSDP_VAR
                    out.add(MSDP_VAR)
                }

                // Read quoted string
                var reading = true
                while (i < srclen && src[i] != IAC && reading) {
                    when (src[i]) {
                        '\\'.code.toByte() -> {
                            i++
                            if (i < srclen && src[i] == '"'.code.toByte()) {
                                out.add(src[i])
                                i++
                            } else {
                                out.add('\\'.code.toByte())
                            }
                        }
                        '"'.code.toByte() -> {
                            i++
                            reading = false
                        }
                        else -> {
                            out.add(src[i])
                            i++
                        }
                    }
                }
            }
            else -> {
                // Unquoted value
                var reading = true
                while (i < srclen && src[i] != IAC && reading) {
                    when (src[i]) {
                        '}'.code.toByte(), ']'.code.toByte(), ','.code.toByte(), ':'.code.toByte() -> {
                            reading = false
                        }
                        ' '.code.toByte() -> {
                            i++
                        }
                        else -> {
                            out.add(src[i])
                            i++
                        }
                    }
                }
            }
        }
    }

    out.add(IAC)
    out.add(SE)
    return out.toByteArray()
}
