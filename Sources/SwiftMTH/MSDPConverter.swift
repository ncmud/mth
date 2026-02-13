// MSDP protocol control bytes
private let MSDP_VAR: UInt8 = 1
private let MSDP_VAL: UInt8 = 2
private let MSDP_TABLE_OPEN: UInt8 = 3
private let MSDP_TABLE_CLOSE: UInt8 = 4
private let MSDP_ARRAY_OPEN: UInt8 = 5
private let MSDP_ARRAY_CLOSE: UInt8 = 6

// Telnet framing bytes
private let IAC: UInt8 = 255
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let TELOPT_MSDP: UInt8 = 69
private let TELOPT_GMCP: UInt8 = 201

/// Convert MSDP binary subnegotiation to GMCP JSON subnegotiation.
///
/// Input: `IAC SB TELOPT_MSDP <msdp data> IAC SE`
/// Output: `IAC SB TELOPT_GMCP MSDP {<json>} IAC SE`
public func msdp2json(_ src: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(src.count * 2)
    let srclen = src.count

    // If MSDP framing, replace with GMCP framing + "MSDP {"
    if srclen >= 3 && src[2] == TELOPT_MSDP {
        out.append(IAC)
        out.append(SB)
        out.append(TELOPT_GMCP)
        out.append(contentsOf: "MSDP {".utf8)
    }

    var i = 3
    var nest = 0
    var last: UInt8 = 0

    while i < srclen {
        if src[i] == IAC && i + 1 < srclen && src[i + 1] == SE {
            break
        }

        switch src[i] {
        case MSDP_TABLE_OPEN:
            out.append(UInt8(ascii: "{"))
            nest += 1
            last = MSDP_TABLE_OPEN

        case MSDP_TABLE_CLOSE:
            if last == MSDP_VAL || last == MSDP_VAR {
                out.append(UInt8(ascii: "\""))
            }
            if nest > 0 { nest -= 1 }
            out.append(UInt8(ascii: "}"))
            last = MSDP_TABLE_CLOSE

        case MSDP_ARRAY_OPEN:
            out.append(UInt8(ascii: "["))
            nest += 1
            last = MSDP_ARRAY_OPEN

        case MSDP_ARRAY_CLOSE:
            if last == MSDP_VAL || last == MSDP_VAR {
                out.append(UInt8(ascii: "\""))
            }
            if nest > 0 { nest -= 1 }
            out.append(UInt8(ascii: "]"))
            last = MSDP_ARRAY_CLOSE

        case MSDP_VAR:
            if last == MSDP_VAL || last == MSDP_VAR {
                out.append(UInt8(ascii: "\""))
            }
            if last == MSDP_VAL || last == MSDP_VAR || last == MSDP_TABLE_CLOSE || last == MSDP_ARRAY_CLOSE {
                out.append(UInt8(ascii: ","))
            }
            out.append(UInt8(ascii: "\""))
            last = MSDP_VAR

        case MSDP_VAL:
            if last == MSDP_VAR {
                out.append(UInt8(ascii: "\""))
                out.append(UInt8(ascii: ":"))
            }
            if last == MSDP_VAL {
                out.append(UInt8(ascii: "\""))
                out.append(UInt8(ascii: ","))
            }
            if i + 1 < srclen && src[i + 1] != MSDP_TABLE_OPEN && src[i + 1] != MSDP_ARRAY_OPEN {
                out.append(UInt8(ascii: "\""))
            }
            last = MSDP_VAL

        case UInt8(ascii: "\\"):
            out.append(UInt8(ascii: "\\"))
            out.append(UInt8(ascii: "\\"))

        case UInt8(ascii: "\""):
            out.append(UInt8(ascii: "\\"))
            out.append(UInt8(ascii: "\""))

        default:
            out.append(src[i])
        }
        i += 1
    }

    // Append closing "}" and IAC SE
    out.append(UInt8(ascii: "}"))
    out.append(IAC)
    out.append(SE)

    return out
}

/// Convert GMCP JSON subnegotiation to MSDP binary subnegotiation.
///
/// Input: `IAC SB TELOPT_GMCP MSDP {<json>} IAC SE`
/// Output: `IAC SB TELOPT_MSDP <msdp data> IAC SE`
public func json2msdp(_ src: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(src.count)
    let srclen = src.count

    // If GMCP framing, replace with MSDP framing
    if srclen >= 3 && src[2] == TELOPT_GMCP {
        out.append(IAC)
        out.append(SB)
        out.append(TELOPT_MSDP)
    }

    var i = 3

    // Skip "MSDP {" prefix if present
    if i + 6 <= srclen {
        let prefix = src[i..<i+6]
        if prefix.elementsEqual("MSDP {".utf8) {
            i += 6
        }
    }

    var state = [Int](repeating: 0, count: 100)
    var nest = 0
    var last: UInt8 = 0
    state[0] = 0

    while i < srclen && src[i] != IAC && nest < 99 {
        switch src[i] {
        case UInt8(ascii: " "):
            i += 1

        case UInt8(ascii: "{"):
            out.append(MSDP_TABLE_OPEN)
            i += 1
            nest += 1
            state[nest] = 0

        case UInt8(ascii: "}"):
            nest -= 1
            i += 1
            if nest < 0 {
                out.append(IAC)
                out.append(SE)
                return out
            }
            out.append(MSDP_TABLE_CLOSE)

        case UInt8(ascii: "["):
            i += 1
            nest += 1
            state[nest] = 1
            out.append(MSDP_ARRAY_OPEN)

        case UInt8(ascii: "]"):
            nest -= 1
            i += 1
            out.append(MSDP_ARRAY_CLOSE)

        case UInt8(ascii: ":"):
            out.append(MSDP_VAL)
            i += 1

        case UInt8(ascii: ","):
            i += 1
            if state[nest] != 0 {
                out.append(MSDP_VAL)
            } else {
                out.append(MSDP_VAR)
            }

        case UInt8(ascii: "\""):
            i += 1
            if last == 0 {
                last = MSDP_VAR
                out.append(MSDP_VAR)
            }

            // Read quoted string
            var reading = true
            while i < srclen && src[i] != IAC && reading {
                switch src[i] {
                case UInt8(ascii: "\\"):
                    i += 1
                    if i < srclen && src[i] == UInt8(ascii: "\"") {
                        out.append(src[i])
                        i += 1
                    } else {
                        out.append(UInt8(ascii: "\\"))
                    }
                case UInt8(ascii: "\""):
                    i += 1
                    reading = false
                default:
                    out.append(src[i])
                    i += 1
                }
            }

        default:
            // Unquoted value
            var reading = true
            while i < srclen && src[i] != IAC && reading {
                switch src[i] {
                case UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: ","), UInt8(ascii: ":"):
                    reading = false
                case UInt8(ascii: " "):
                    i += 1
                default:
                    out.append(src[i])
                    i += 1
                }
            }
        }
    }

    out.append(IAC)
    out.append(SE)
    return out
}
