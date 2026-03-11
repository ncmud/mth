package mth.color

import kotlin.random.Random

fun substituteColor(input: String, depth: ColorDepth): String {
    val bytes = input.toByteArray(Charsets.UTF_8) + 0.toByte() // null terminator
    val output = mutableListOf<Byte>()
    substituteColorBytes(bytes, output, depth.colors)
    return String(output.toByteArray(), Charsets.UTF_8)
}

private fun substituteColorBytes(input: ByteArray, output: MutableList<Byte>, colors: Int): Int {
    val startCount = output.size
    val oldF = ByteArray(7) // tracks last foreground code
    val oldB = ByteArray(7) // tracks last background code
    var i = 0

    while (i < input.size && input[i] != 0.toByte()) {
        val c = input[i].toInt() and 0xFF

        when (c) {
            '^'.code -> {
                val next = if (i + 1 < input.size) input[i + 1] else 0.toByte()
                if (ColorTables.is32c(next) != 0) {
                    // Skip pattern: ^r^^g skips ^r, processes ^g
                    if (i + 3 < input.size &&
                        input[i + 2] == '^'.code.toByte() &&
                        ColorTables.is32c(input[i + 3]) != 0
                    ) {
                        i += 2
                        continue
                    }

                    if (colors != 0) {
                        val nextUnsigned = next.toInt() and 0xFF
                        if (nextUnsigned == '?'.code) {
                            // Random color
                            val rndCode = randomTrueColorCode()
                            val rndBytes = rndCode.toByteArray(Charsets.UTF_8) + 0.toByte()
                            substituteColorBytes(rndBytes, output, colors)
                        } else if (oldF[0] != input[i] || oldF[1] != next) {
                            // Different from last foreground -- emit ANSI
                            if (nextUnsigned in 'a'.code..'z'.code) {
                                val idx = nextUnsigned - 'a'.code
                                val expanded = ColorTables.alphabetFgcDark[idx]
                                val expandedBytes = expanded.toByteArray(Charsets.UTF_8) + 0.toByte()
                                val cappedColors = if (colors < 256) colors else 256
                                substituteColorBytes(expandedBytes, output, cappedColors)
                            } else {
                                val idx = nextUnsigned - 'A'.code
                                val expanded = ColorTables.alphabetFgcBold[idx]
                                val expandedBytes = expanded.toByteArray(Charsets.UTF_8) + 0.toByte()
                                val cappedColors = if (colors < 256) colors else 256
                                substituteColorBytes(expandedBytes, output, cappedColors)
                            }
                        }
                    }
                    // Update oldF
                    oldF[0] = input[i]
                    oldF[1] = next
                    i += 2
                } else {
                    if ((next.toInt() and 0xFF) == '^'.code) {
                        // ^^ escape -- skip first ^, output second
                        i += 1
                    }
                    output.add(input[i])
                    i += 1
                }
            }

            '<'.code -> {
                if (matchesForegroundCode(input, i)) {
                    val c2 = input[i + 2]
                    val c3 = input[i + 3]
                    val c4 = input[i + 4]
                    val normalized = normalizedFCode(c2, c3, c4)

                    if (!caseInsensitiveMatch6(oldF, input, i) && colors != 0) {
                        if (colors == 4096) {
                            val r = ColorTables.tcVal(c2)
                            val g = ColorTables.tcVal(c3)
                            val b = ColorTables.tcVal(c4)
                            appendString(output, "\u001B[38;2;${r};${g};${b}m")
                        } else if (colors == 256) {
                            val idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                            appendString(output, "\u001B[38;5;${idx}m")
                        } else {
                            // 16 colors -- recurse through ANSI table
                            val idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                            val ansi = ColorTables.ansiForeground[idx]
                            val ansiBytes = ansi.toByteArray(Charsets.UTF_8) + 0.toByte()
                            substituteColorBytes(ansiBytes, output, colors)
                        }
                    }
                    for (j in 0 until 6) oldF[j] = normalized[j]
                    i += 6
                } else if (matchesBackgroundCode(input, i)) {
                    val c2 = input[i + 2]
                    val c3 = input[i + 3]
                    val c4 = input[i + 4]
                    val normalized = normalizedFCode(c2, c3, c4) // C uses F for both

                    if (!caseInsensitiveMatch6(oldB, input, i) && colors != 0) {
                        if (colors == 4096) {
                            val r = ColorTables.tcVal(c2)
                            val g = ColorTables.tcVal(c3)
                            val b = ColorTables.tcVal(c4)
                            appendString(output, "\u001B[48;2;${r};${g};${b}m")
                        } else if (colors == 256) {
                            val idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                            appendString(output, "\u001B[48;5;${idx}m")
                        } else {
                            val idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                            val ansi = ColorTables.ansiBackground[idx]
                            val ansiBytes = ansi.toByteArray(Charsets.UTF_8) + 0.toByte()
                            substituteColorBytes(ansiBytes, output, colors)
                        }
                    }
                    for (j in 0 until 6) oldB[j] = normalized[j]
                    i += 6
                } else {
                    output.add(input[i])
                    i += 1
                }
            }

            else -> {
                output.add(input[i])
                i += 1
            }
        }
    }

    return output.size - startCount
}

private fun isHexDigit(c: Byte): Boolean {
    val v = c.toInt() and 0xFF
    return v in '0'.code..'9'.code || v in 'A'.code..'F'.code || v in 'a'.code..'f'.code
}

private fun toUpper(c: Byte): Byte {
    val v = c.toInt() and 0xFF
    return if (v in 'a'.code..'z'.code) (v - 32).toByte() else c
}

private fun matchesForegroundCode(input: ByteArray, at: Int): Boolean {
    if (at + 5 >= input.size) return false
    if ((input[at].toInt() and 0xFF) != '<'.code) return false
    val tag = input[at + 1].toInt() and 0xFF
    if (tag != 'F'.code && tag != 'f'.code) return false
    if (!isHexDigit(input[at + 2])) return false
    if (!isHexDigit(input[at + 3])) return false
    if (!isHexDigit(input[at + 4])) return false
    if ((input[at + 5].toInt() and 0xFF) != '>'.code) return false
    return true
}

private fun matchesBackgroundCode(input: ByteArray, at: Int): Boolean {
    if (at + 5 >= input.size) return false
    if ((input[at].toInt() and 0xFF) != '<'.code) return false
    val tag = input[at + 1].toInt() and 0xFF
    if (tag != 'B'.code && tag != 'b'.code) return false
    if (!isHexDigit(input[at + 2])) return false
    if (!isHexDigit(input[at + 3])) return false
    if (!isHexDigit(input[at + 4])) return false
    if ((input[at + 5].toInt() and 0xFF) != '>'.code) return false
    return true
}

private fun normalizedFCode(c2: Byte, c3: Byte, c4: Byte): ByteArray {
    return byteArrayOf(
        '<'.code.toByte(),
        'F'.code.toByte(),
        toUpper(c2),
        toUpper(c3),
        toUpper(c4),
        '>'.code.toByte(),
        0.toByte()
    )
}

private fun caseInsensitiveMatch6(old: ByteArray, input: ByteArray, at: Int): Boolean {
    for (j in 0 until 6) {
        if (at + j >= input.size) return false
        if (toUpper(old[j]) != toUpper(input[at + j])) return false
    }
    return true
}

private fun appendString(output: MutableList<Byte>, s: String) {
    for (b in s.toByteArray(Charsets.UTF_8)) {
        output.add(b)
    }
}

private fun randomTrueColorCode(): String {
    val r = ColorTables.decToHex[Random.nextInt(16)]
    val g = ColorTables.decToHex[Random.nextInt(16)]
    val b = ColorTables.decToHex[Random.nextInt(16)]
    return "<F${r}${g}${b}>"
}
