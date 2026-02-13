#if canImport(Cmth)
import Testing
import Cmth
import MTH

// Telnet/MSDP constants
private let IAC: UInt8 = 255
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let TELOPT_MSDP: UInt8 = 69
private let TELOPT_GMCP: UInt8 = 201
private let MV: UInt8 = 1  // MSDP_VAR
private let ML: UInt8 = 2  // MSDP_VAL
private let TO: UInt8 = 3  // MSDP_TABLE_OPEN
private let TC: UInt8 = 4  // MSDP_TABLE_CLOSE
private let AO: UInt8 = 5  // MSDP_ARRAY_OPEN
private let AC: UInt8 = 6  // MSDP_ARRAY_CLOSE

/// Call C msdp2json and return result as [UInt8].
private func cMsdp2Json(_ input: [UInt8]) -> [UInt8] {
    var src = input
    var out = [UInt8](repeating: 0, count: input.count * 4 + 256)
    let len = src.withUnsafeMutableBufferPointer { srcPtr in
        out.withUnsafeMutableBufferPointer { outPtr in
            Cmth.msdp2json(
                srcPtr.baseAddress,
                Int32(srcPtr.count),
                outPtr.baseAddress?.withMemoryRebound(to: CChar.self, capacity: outPtr.count) { $0 }
            )
        }
    }
    return Array(out.prefix(Int(len)))
}

/// Call C json2msdp and return result as [UInt8].
private func cJson2Msdp(_ input: [UInt8]) -> [UInt8] {
    var src = input
    var out = [UInt8](repeating: 0, count: input.count * 4 + 256)
    let len = src.withUnsafeMutableBufferPointer { srcPtr in
        out.withUnsafeMutableBufferPointer { outPtr in
            Cmth.json2msdp(
                srcPtr.baseAddress,
                Int32(srcPtr.count),
                outPtr.baseAddress?.withMemoryRebound(to: CChar.self, capacity: outPtr.count) { $0 }
            )
        }
    }
    return Array(out.prefix(Int(len)))
}

/// Build an MSDP subnegotiation packet.
private func msdpPacket(_ payload: [UInt8]) -> [UInt8] {
    [IAC, SB, TELOPT_MSDP] + payload + [IAC, SE]
}

/// Build a GMCP subnegotiation packet.
private func gmcpPacket(_ payload: [UInt8]) -> [UInt8] {
    [IAC, SB, TELOPT_GMCP] + payload + [IAC, SE]
}

// MARK: - msdp2json Oracle Tests

@Test func msdp2jsonSimpleVarVal() {
    // MSDP_VAR "HP" MSDP_VAL "100"
    let input = msdpPacket([MV] + Array("HP".utf8) + [ML] + Array("100".utf8))
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Simple var/val mismatch")
}

@Test func msdp2jsonMultipleVars() {
    // MSDP_VAR "HP" MSDP_VAL "100" MSDP_VAR "MP" MSDP_VAL "50"
    let input = msdpPacket(
        [MV] + Array("HP".utf8) + [ML] + Array("100".utf8) +
        [MV] + Array("MP".utf8) + [ML] + Array("50".utf8)
    )
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Multiple vars mismatch")
}

@Test func msdp2jsonNestedTable() {
    // MSDP_VAR "STATS" MSDP_VAL MSDP_TABLE_OPEN MSDP_VAR "HP" MSDP_VAL "100" MSDP_TABLE_CLOSE
    let input = msdpPacket(
        [MV] + Array("STATS".utf8) + [ML, TO] +
        [MV] + Array("HP".utf8) + [ML] + Array("100".utf8) +
        [TC]
    )
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Nested table mismatch")
}

@Test func msdp2jsonArray() {
    // MSDP_VAR "LIST" MSDP_VAL MSDP_ARRAY_OPEN MSDP_VAL "a" MSDP_VAL "b" MSDP_ARRAY_CLOSE
    let input = msdpPacket(
        [MV] + Array("LIST".utf8) + [ML, AO] +
        [ML] + Array("a".utf8) +
        [ML] + Array("b".utf8) +
        [AC]
    )
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Array mismatch")
}

@Test func msdp2jsonEscaping() {
    // Value with backslash and quote
    let input = msdpPacket(
        [MV] + Array("MSG".utf8) + [ML] + Array("say \"hello\"".utf8)
    )
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Escaping mismatch")
}

@Test func msdp2jsonEmptyValue() {
    let input = msdpPacket([MV] + Array("X".utf8) + [ML])
    let cResult = cMsdp2Json(input)
    let swiftResult = msdp2json(input)
    #expect(swiftResult == cResult, "Empty value mismatch")
}

// MARK: - json2msdp Oracle Tests

@Test func json2msdpSimpleVarVal() {
    let input = gmcpPacket(Array("MSDP {\"HP\":\"100\"}".utf8))
    let cResult = cJson2Msdp(input)
    let swiftResult = json2msdp(input)
    #expect(swiftResult == cResult, "Simple json2msdp mismatch")
}

@Test func json2msdpMultipleVars() {
    let input = gmcpPacket(Array("MSDP {\"HP\":\"100\",\"MP\":\"50\"}".utf8))
    let cResult = cJson2Msdp(input)
    let swiftResult = json2msdp(input)
    #expect(swiftResult == cResult, "Multiple vars json2msdp mismatch")
}

@Test func json2msdpNestedTable() {
    let input = gmcpPacket(Array("MSDP {\"STATS\":{\"HP\":\"100\"}}".utf8))
    let cResult = cJson2Msdp(input)
    let swiftResult = json2msdp(input)
    #expect(swiftResult == cResult, "Nested table json2msdp mismatch")
}

@Test func json2msdpArray() {
    let input = gmcpPacket(Array("MSDP {\"LIST\":[\"a\",\"b\"]}".utf8))
    let cResult = cJson2Msdp(input)
    let swiftResult = json2msdp(input)
    #expect(swiftResult == cResult, "Array json2msdp mismatch")
}

@Test func json2msdpEscaping() {
    let input = gmcpPacket(Array("MSDP {\"MSG\":\"say \\\"hello\\\"\"}".utf8))
    let cResult = cJson2Msdp(input)
    let swiftResult = json2msdp(input)
    #expect(swiftResult == cResult, "Escaping json2msdp mismatch")
}

// MARK: - Round-trip Tests

@Test func roundTripMsdpToJsonToMsdp() {
    var payload: [UInt8] = []
    payload += [MV] + Array("HP".utf8) + [ML] + Array("100".utf8)
    payload += [MV] + Array("ROOM".utf8) + [ML, TO]
    payload += [MV] + Array("NAME".utf8) + [ML] + Array("Town".utf8)
    payload += [TC]
    let original = msdpPacket(payload)
    let json = msdp2json(original)
    let backToMsdp = json2msdp(json)
    let cJson = cMsdp2Json(original)
    let cBackToMsdp = cJson2Msdp(cJson)
    #expect(backToMsdp == cBackToMsdp, "Round-trip mismatch")
}
#endif
