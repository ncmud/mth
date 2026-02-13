/// Substitute MUD color codes in the input string, producing ANSI escape sequences
/// appropriate for the given color depth.
///
/// Supports three color code syntaxes:
/// - `^a`-`^z` / `^A`-`^Z`: 32 named MUD colors (dark/bright)
/// - `<F000>`-`<FFFF>`: True color foreground (hex RGB)
/// - `<B000>`-`<BFFF>`: True color background (hex RGB)
/// - `^^`: Escaped literal caret
/// - `^?`: Random color
public func substituteColor(_ input: String, depth: ColorDepth) -> String {
    var bytes = Array(input.utf8)
    bytes.append(0) // null terminator for C-like iteration
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count * 6)
    substituteColorBytes(bytes, into: &output, colors: depth.rawValue)
    return String(decoding: output, as: UTF8.self)
}

/// Internal recursive implementation operating on byte arrays.
/// Returns number of bytes written to output (for recursive calls).
@discardableResult
private func substituteColorBytes(_ input: [UInt8], into output: inout [UInt8], colors: Int) -> Int {
    let startCount = output.count
    var oldF: [UInt8] = [0, 0, 0, 0, 0, 0, 0] // tracks last foreground code
    var oldB: [UInt8] = [0, 0, 0, 0, 0, 0, 0] // tracks last background code
    var i = 0

    while i < input.count && input[i] != 0 {
        switch input[i] {
        case UInt8(ascii: "^"):
            let next = i + 1 < input.count ? input[i + 1] : 0
            if ColorTables.is32c(next) != 0 {
                // Skip pattern: ^r^^g skips ^r, processes ^g
                if i + 3 < input.count && input[i + 2] == UInt8(ascii: "^") && ColorTables.is32c(input[i + 3]) != 0 {
                    i += 2
                    continue
                }

                if colors != 0 {
                    if next == UInt8(ascii: "?") {
                        // Random color — generate a random <Fxxx> code and recurse
                        let rndCode = randomTrueColorCode()
                        var rndBytes = Array(rndCode.utf8)
                        rndBytes.append(0)
                        substituteColorBytes(rndBytes, into: &output, colors: colors)
                    } else if oldF[0] != input[i] || oldF[1] != next {
                        // Different from last foreground — emit ANSI
                        if next >= UInt8(ascii: "a") && next <= UInt8(ascii: "z") {
                            let idx = Int(next) - Int(UInt8(ascii: "a"))
                            let expanded = ColorTables.alphabetFgcDark[idx]
                            var expandedBytes = Array(expanded.utf8)
                            expandedBytes.append(0)
                            let cappedColors = colors < 256 ? colors : 256
                            substituteColorBytes(expandedBytes, into: &output, colors: cappedColors)
                        } else {
                            let idx = Int(next) - Int(UInt8(ascii: "A"))
                            let expanded = ColorTables.alphabetFgcBold[idx]
                            var expandedBytes = Array(expanded.utf8)
                            expandedBytes.append(0)
                            let cappedColors = colors < 256 ? colors : 256
                            substituteColorBytes(expandedBytes, into: &output, colors: cappedColors)
                        }
                    }
                }
                // Update old_f and advance past 2-char code
                oldF[0] = input[i]
                oldF[1] = next
                i += 2

            } else {
                // Not a valid 32-color code
                if next == UInt8(ascii: "^") {
                    // ^^ escape — skip first ^, output second
                    i += 1
                }
                output.append(input[i])
                i += 1
            }

        case UInt8(ascii: "<"):
            if matchesForegroundCode(input, at: i) {
                let c2 = input[i + 2], c3 = input[i + 3], c4 = input[i + 4]
                let normalized = normalizedFCode(c2, c3, c4)

                if !caseInsensitiveMatch6(oldF, input, at: i) && colors != 0 {
                    if colors == 4096 {
                        let r = ColorTables.tcVal(c2)
                        let g = ColorTables.tcVal(c3)
                        let b = ColorTables.tcVal(c4)
                        appendString(&output, "\u{1B}[38;2;\(r);\(g);\(b)m")
                    } else if colors == 256 {
                        let idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                        appendString(&output, "\u{1B}[38;5;\(idx)m")
                    } else {
                        // 16 colors — recurse through ANSI table
                        let idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                        let ansi = ColorTables.ansiForeground[idx]
                        var ansiBytes = Array(ansi.utf8)
                        ansiBytes.append(0)
                        substituteColorBytes(ansiBytes, into: &output, colors: colors)
                    }
                }
                // Update old_f to normalized form and advance
                for j in 0..<6 { oldF[j] = normalized[j] }
                i += 6

            } else if matchesBackgroundCode(input, at: i) {
                let c2 = input[i + 2], c3 = input[i + 3], c4 = input[i + 4]
                let normalized = normalizedFCode(c2, c3, c4) // C uses "<F%c%c%c>" for both

                if !caseInsensitiveMatch6(oldB, input, at: i) && colors != 0 {
                    if colors == 4096 {
                        let r = ColorTables.tcVal(c2)
                        let g = ColorTables.tcVal(c3)
                        let b = ColorTables.tcVal(c4)
                        appendString(&output, "\u{1B}[48;2;\(r);\(g);\(b)m")
                    } else if colors == 256 {
                        let idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                        appendString(&output, "\u{1B}[48;5;\(idx)m")
                    } else {
                        let idx = 16 + ColorTables.x256cVal(c2) * 36 + ColorTables.x256cVal(c3) * 6 + ColorTables.x256cVal(c4)
                        let ansi = ColorTables.ansiBackground[idx]
                        var ansiBytes = Array(ansi.utf8)
                        ansiBytes.append(0)
                        substituteColorBytes(ansiBytes, into: &output, colors: colors)
                    }
                }
                // C stores as "<F%c%c%c>" for old_b too (yes, F not B — matches C bug/behavior)
                for j in 0..<6 { oldB[j] = normalized[j] }
                i += 6

            } else {
                output.append(input[i])
                i += 1
            }

        default:
            output.append(input[i])
            i += 1
        }
    }

    return output.count - startCount
}

// MARK: - Helpers

private func appendString(_ output: inout [UInt8], _ s: String) {
    output.append(contentsOf: s.utf8)
}

/// Check if input at position i matches <Fxxx> or <fxxx> pattern.
private func matchesForegroundCode(_ input: [UInt8], at i: Int) -> Bool {
    guard i + 5 < input.count else { return false }
    let ch1 = input[i + 1]
    return (ch1 == UInt8(ascii: "F") || ch1 == UInt8(ascii: "f"))
        && isHexDigit(input[i + 2])
        && isHexDigit(input[i + 3])
        && isHexDigit(input[i + 4])
        && input[i + 5] == UInt8(ascii: ">")
}

/// Check if input at position i matches <Bxxx> or <bxxx> pattern.
private func matchesBackgroundCode(_ input: [UInt8], at i: Int) -> Bool {
    guard i + 5 < input.count else { return false }
    let ch1 = input[i + 1]
    return (ch1 == UInt8(ascii: "B") || ch1 == UInt8(ascii: "b"))
        && isHexDigit(input[i + 2])
        && isHexDigit(input[i + 3])
        && isHexDigit(input[i + 4])
        && input[i + 5] == UInt8(ascii: ">")
}

private func isHexDigit(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
        || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f"))
        || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F"))
}

private func toUpper(_ c: UInt8) -> UInt8 {
    if c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") {
        return c - 32
    }
    return c
}

/// Produce the normalized "<Fxxx>" form used for old_f/old_b tracking.
/// The C code uses `sprintf(old_f, "<F%c%c%c>", pti[2], pti[3], pti[4])`.
private func normalizedFCode(_ c2: UInt8, _ c3: UInt8, _ c4: UInt8) -> [UInt8] {
    [UInt8(ascii: "<"), UInt8(ascii: "F"), c2, c3, c4, UInt8(ascii: ">"), 0]
}

/// Case-insensitive comparison of first 6 bytes of `old` against `input[at..<at+6]`.
private func caseInsensitiveMatch6(_ old: [UInt8], _ input: [UInt8], at i: Int) -> Bool {
    guard i + 5 < input.count else { return false }
    for j in 0..<6 {
        if toUpper(old[j]) != toUpper(input[i + j]) {
            return false
        }
    }
    return true
}

/// Generate a random true color code string like "<F8A3>".
private func randomTrueColorCode() -> String {
    let hex = ColorTables.decToHex
    let r = hex[Int.random(in: 0..<16)]
    let g = hex[Int.random(in: 0..<16)]
    let b = hex[Int.random(in: 0..<16)]
    return "<F\(r)\(g)\(b)>"
}
