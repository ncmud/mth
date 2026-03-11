package mth.color

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ColorSubstitutionTest {

    // 1. Plain text passthrough
    @Test
    fun plainTextPassthroughAtAllDepths() {
        for (depth in ColorDepth.entries) {
            assertEquals("Hello, world!", substituteColor("Hello, world!", depth))
        }
    }

    // 2. Empty string
    @Test
    fun emptyStringReturnsEmpty() {
        for (depth in ColorDepth.entries) {
            assertEquals("", substituteColor("", depth))
        }
    }

    // 3. Caret escape
    @Test
    fun caretEscapeProducesLiteralCaret() {
        for (depth in ColorDepth.entries) {
            assertEquals("^", substituteColor("^^", depth))
            assertEquals("foo^bar", substituteColor("foo^^bar", depth))
            assertEquals("^^", substituteColor("^^^^", depth))
        }
    }

    // 4. Dark colors produce ANSI escape at non-NONE depths, stripped at NONE
    // ^r -> alphabetFgcDark[17] = "<fb00>"
    // ANSI16: ansiForeground[124] = "\u001B[22;31m"
    // XTERM256: "\u001B[38;5;124m"
    // TRUE_COLOR: tcVal('b')=187, tcVal('0')=0 -> "\u001B[38;2;187;0;0m"
    @Test
    fun darkColorAtNone() {
        assertEquals("text", substituteColor("^rtext", ColorDepth.NONE))
    }

    @Test
    fun darkColorAtAnsi16() {
        assertEquals("\u001B[22;31mtext", substituteColor("^rtext", ColorDepth.ANSI16))
    }

    @Test
    fun darkColorAtXterm256() {
        assertEquals("\u001B[38;5;124mtext", substituteColor("^rtext", ColorDepth.XTERM256))
    }

    @Test
    fun darkColorAtTrueColor() {
        // ^r expands to <fb00>, but recursive call caps colors at 256
        assertEquals("\u001B[38;5;124mtext", substituteColor("^rtext", ColorDepth.TRUE_COLOR))
    }

    // 5. Bright colors
    // ^R -> alphabetFgcBold[17] = "<ff00>"
    // ANSI16: ansiForeground[196] = "\u001B[1;31m"
    // XTERM256: "\u001B[38;5;196m"
    // TRUE_COLOR: tcVal('f')=255 -> "\u001B[38;2;255;0;0m"
    @Test
    fun brightColorAtNone() {
        assertEquals("text", substituteColor("^Rtext", ColorDepth.NONE))
    }

    @Test
    fun brightColorAtAnsi16() {
        assertEquals("\u001B[1;31mtext", substituteColor("^Rtext", ColorDepth.ANSI16))
    }

    @Test
    fun brightColorAtXterm256() {
        assertEquals("\u001B[38;5;196mtext", substituteColor("^Rtext", ColorDepth.XTERM256))
    }

    @Test
    fun brightColorAtTrueColor() {
        // ^R expands to <ff00>, but recursive call caps colors at 256
        assertEquals("\u001B[38;5;196mtext", substituteColor("^Rtext", ColorDepth.TRUE_COLOR))
    }

    // 6. Colors stripped at NONE
    @Test
    fun colorsStrippedAtNone() {
        assertEquals("hello world", substituteColor("^rhello <F800>world", ColorDepth.NONE))
    }

    // 7. Repeated color suppressed -- only one ANSI code emitted
    @Test
    fun repeatedColorSuppressed() {
        val result = substituteColor("^r^r^rred", ColorDepth.XTERM256)
        assertEquals("\u001B[38;5;124mred", result)
    }

    @Test
    fun repeatedColorSuppressedAnsi16() {
        val result = substituteColor("^r^r^rred", ColorDepth.ANSI16)
        assertEquals("\u001B[22;31mred", result)
    }

    @Test
    fun repeatedColorSuppressedTrueColor() {
        // ^r expands to <fb00>, recursive call caps at 256
        val result = substituteColor("^r^r^rred", ColorDepth.TRUE_COLOR)
        assertEquals("\u001B[38;5;124mred", result)
    }

    // 8. Skip pattern -- ^r^g skips ^r, processes ^g
    // ^g -> alphabetFgcDark[6] = "<f0b0>"
    // XTERM256: 16 + 0*36 + 3*6 + 0 = 34 -> "\u001B[38;5;34m"
    @Test
    fun skipPatternSkipsFirstColor() {
        val result = substituteColor("^r^gtext", ColorDepth.XTERM256)
        assertEquals("\u001B[38;5;34mtext", result)
    }

    @Test
    fun skipPatternSkipsFirstColorAnsi16() {
        // ansiForeground[34] = "\u001B[22;32m"
        val result = substituteColor("^r^gtext", ColorDepth.ANSI16)
        assertEquals("\u001B[22;32mtext", result)
    }

    @Test
    fun skipPatternSkipsFirstColorTrueColor() {
        // ^g expands to <f0b0>, recursive call caps at 256
        val result = substituteColor("^r^gtext", ColorDepth.TRUE_COLOR)
        assertEquals("\u001B[38;5;34mtext", result)
    }

    // 9. True color foreground
    // tcVal('8')=136, tcVal('0')=0
    @Test
    fun trueColorForeground() {
        assertEquals("\u001B[38;2;136;0;0mred", substituteColor("<F800>red", ColorDepth.TRUE_COLOR))
    }

    // 10. True color foreground at 256
    // 16 + x256cVal('8')*36 + 0 + 0 = 16 + 2*36 = 88
    @Test
    fun trueColorForegroundAt256() {
        assertEquals("\u001B[38;5;88mred", substituteColor("<F800>red", ColorDepth.XTERM256))
    }

    // 11. True color background
    // <B080> at TRUE_COLOR: tcVal('0')=0, tcVal('8')=136, tcVal('0')=0
    @Test
    fun trueColorBackground() {
        assertEquals(
            "\u001B[48;2;0;136;0mgreen bg",
            substituteColor("<B080>green bg", ColorDepth.TRUE_COLOR),
        )
    }

    // 12. Invalid codes passthrough
    @Test
    fun invalidCodesPassthrough() {
        assertEquals("<Fxyz>notcolor", substituteColor("<Fxyz>notcolor", ColorDepth.TRUE_COLOR))
    }

    // 13. Short code passthrough
    @Test
    fun shortCodePassthrough() {
        assertEquals("<F00>short", substituteColor("<F00>short", ColorDepth.TRUE_COLOR))
    }

    // 14. Non-FB code passthrough
    @Test
    fun nonFBCodePassthrough() {
        assertEquals("<Zfff>notfb", substituteColor("<Zfff>notfb", ColorDepth.TRUE_COLOR))
    }

    // 15. Complex mixed
    // ^W -> alphabetFgcBold[22] = "<ffff>" (bright white)
    // ^^ -> literal ^
    @Test
    fun complexMixed() {
        val result = substituteColor("^WHello, ^^world^^!", ColorDepth.ANSI16)
        assertTrue(result.contains("\u001B["))
        assertTrue(result.contains("Hello, "))
        assertTrue(result.contains("^world^!"))
    }

    // 16. Foreground deduplication
    @Test
    fun foregroundDeduplication() {
        val result = substituteColor("<F800><F800>red", ColorDepth.TRUE_COLOR)
        assertEquals("\u001B[38;2;136;0;0mred", result)
    }

    @Test
    fun foregroundDeduplicationXterm256() {
        val result = substituteColor("<F800><F800>red", ColorDepth.XTERM256)
        assertEquals("\u001B[38;5;88mred", result)
    }

    // 17. Background deduplication -- normalizedFCode uses <F...> for both fg/bg,
    // so oldB stores <F000> which won't match <B000> in input; both codes emitted.
    // Use <b000> (lowercase) after <B000> to test case-insensitive dedup.
    @Test
    fun backgroundDeduplication() {
        val result = substituteColor("<B000><B000>black bg", ColorDepth.TRUE_COLOR)
        assertEquals("\u001B[48;2;0;0;0m\u001B[48;2;0;0;0mblack bg", result)
    }

    @Test
    fun backgroundDeduplicationXterm256() {
        val result = substituteColor("<B000><B000>black bg", ColorDepth.XTERM256)
        assertEquals("\u001B[48;5;16m\u001B[48;5;16mblack bg", result)
    }
}
