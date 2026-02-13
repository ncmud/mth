import Testing
import CmthColor
import MTHColor

/// Call the C substitute_color and return the result as a Swift String.
private func cSubstituteColor(_ input: String, colors: Int32) -> String {
    var inputBuf = Array(input.utf8) + [0]
    var outputBuf = [UInt8](repeating: 0, count: inputBuf.count * 6)
    inputBuf.withUnsafeMutableBufferPointer { inPtr in
        outputBuf.withUnsafeMutableBufferPointer { outPtr in
            _ = substitute_color(
                inPtr.baseAddress?.withMemoryRebound(to: CChar.self, capacity: inPtr.count) { $0 },
                outPtr.baseAddress?.withMemoryRebound(to: CChar.self, capacity: outPtr.count) { $0 },
                colors
            )
        }
    }
    return String(cString: outputBuf)
}

/// Compare C and Swift implementations for the same input/depth.
private func assertOracleMatch(_ input: String, depth: ColorDepth, sourceLocation: SourceLocation = #_sourceLocation) {
    let cResult = cSubstituteColor(input, colors: Int32(depth.rawValue))
    let swiftResult = substituteColor(input, depth: depth)
    #expect(swiftResult == cResult, "Mismatch for depth \(depth) input: \(input.debugDescription)", sourceLocation: sourceLocation)
}

// MARK: - Plain Text

@Test func plainTextPassthrough() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("Hello, world!", depth: depth)
        assertOracleMatch("", depth: depth)
        assertOracleMatch("No color codes here.", depth: depth)
    }
}

// MARK: - Caret Escape

@Test func caretEscape() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("^^", depth: depth)
        assertOracleMatch("foo^^bar", depth: depth)
        assertOracleMatch("^^^^", depth: depth)
    }
}

// MARK: - 32 Color Codes (^a-^z, ^A-^Z)

@Test func darkColors() {
    let validDark: [Character] = ["a", "b", "c", "e", "g", "j", "l", "m", "o", "p", "r", "s", "t", "v", "w", "y"]
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        for ch in validDark {
            assertOracleMatch("^\(ch)text", depth: depth)
        }
    }
}

@Test func brightColors() {
    let validBright: [Character] = ["A", "B", "C", "E", "G", "J", "L", "M", "O", "P", "R", "S", "T", "V", "W", "Y"]
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        for ch in validBright {
            assertOracleMatch("^\(ch)text", depth: depth)
        }
    }
}

@Test func mixedColorCodes() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("^rhello ^gworld", depth: depth)
        assertOracleMatch("^Wbright ^eebony", depth: depth)
    }
}

// MARK: - Color Deduplication (old_f/old_b)

@Test func repeatedColorSuppressed() {
    for depth in [ColorDepth.ansi16, .xterm256, .trueColor] {
        assertOracleMatch("^r^r^rred", depth: depth)
        assertOracleMatch("<F800><F800>red", depth: depth)
    }
}

// MARK: - Skip Pattern (^x^^y)

@Test func skipPattern() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        // ^r^^g means skip ^r, process ^g
        assertOracleMatch("^r^^gtext", depth: depth)
        assertOracleMatch("^a^^btest", depth: depth)
    }
}

// MARK: - True Color Foreground <Fxxx>

@Test func trueColorForeground() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("<F000>black", depth: depth)
        assertOracleMatch("<FFFF>white", depth: depth)
        assertOracleMatch("<F800>red", depth: depth)
        assertOracleMatch("<f800>lowercase", depth: depth)
    }
}

// MARK: - True Color Background <Bxxx>

@Test func trueColorBackground() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("<B000>black bg", depth: depth)
        assertOracleMatch("<BFFF>white bg", depth: depth)
        assertOracleMatch("<B080>green bg", depth: depth)
        assertOracleMatch("<b080>lowercase", depth: depth)
    }
}

// MARK: - Colors Stripped at Depth None

@Test func strippedAtNone() {
    let input = "^rhello <F800>world <B080>bg"
    assertOracleMatch(input, depth: .none)
}

// MARK: - Invalid Color Codes Passed Through

@Test func invalidCodesPassthrough() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("<Fxyz>notcolor", depth: depth)
        assertOracleMatch("<F00>short", depth: depth)
        assertOracleMatch("<F0000>toolong", depth: depth)
        assertOracleMatch("^1nocolor", depth: depth)
        assertOracleMatch("<Zfff>notfb", depth: depth)
    }
}

// MARK: - Complex Mixed Input

@Test func complexMixed() {
    for depth in [ColorDepth.none, .ansi16, .xterm256, .trueColor] {
        assertOracleMatch("^WHello, ^^world^^! <F800>Red <B00F>on blue.", depth: depth)
        assertOracleMatch("^a^b^c^e^g^j^l^m^o^p^r^s^t^v^w^y", depth: depth)
        assertOracleMatch("<FABC><BDEF>truemix", depth: depth)
    }
}
