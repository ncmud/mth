import Foundation
import Testing
import MTH

private let IAC: UInt8 = 255
private let DONT: UInt8 = 254
private let DO: UInt8 = 253
private let WILL: UInt8 = 251
private let SB: UInt8 = 250
private let SE: UInt8 = 240
private let MXP: UInt8 = 91

// ESC[7z — Lock Locked (persistent locked default line mode)
private let lockedDefault: [UInt8] = [0x1B, 0x5B, 0x37, 0x7A]

private let mxpStart: [UInt8] = [IAC, SB, MXP, IAC, SE]

@Suite("MXP negotiation")
struct MXPNegotiationTests {

    @Test func announcesWillMxp() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        s.announceSupport()
        #expect(containsSubsequence(d.allBytes, [IAC, WILL, MXP]))
    }

    @Test func doMxpEnablesAndLocksDefault() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        _ = s.processInput([IAC, DO, MXP])
        #expect(s.mxpEnabled)
        #expect(containsSubsequence(d.allBytes, lockedDefault))
    }

    @Test func doMxpSendsStartCommandBeforeLockedDefault() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        _ = s.processInput([IAC, DO, MXP])
        let bytes = d.allBytes
        #expect(containsSubsequence(bytes, mxpStart))
        // The start command must precede the line-mode escape: a client that is
        // inert until the start command would otherwise miss the locked default.
        if let startIndex = firstIndexOfSubsequence(bytes, mxpStart),
           let lockIndex = firstIndexOfSubsequence(bytes, lockedDefault) {
            #expect(startIndex < lockIndex)
        }
    }

    @Test func reassertResendsStartCommandAndLockedDefault() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        _ = s.processInput([IAC, DO, MXP])
        d.writtenChunks.removeAll()
        s.reassertMXP()
        #expect(containsSubsequence(d.allBytes, mxpStart))
        #expect(containsSubsequence(d.allBytes, lockedDefault))
    }

    @Test func dontMxpDisables() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        _ = s.processInput([IAC, DO, MXP])
        #expect(s.mxpEnabled)
        _ = s.processInput([IAC, DONT, MXP])
        #expect(!s.mxpEnabled)
    }

    @Test func doMxpIsIdempotent() {
        let d = FakeDelegateMXP()
        let s = TelnetSession(delegate: d)
        _ = s.processInput([IAC, DO, MXP])
        d.writtenChunks.removeAll()
        _ = s.processInput([IAC, DO, MXP])
        // Second DO MXP should not re-emit the start command or locked-default marker.
        #expect(!containsSubsequence(d.allBytes, mxpStart))
        #expect(!containsSubsequence(d.allBytes, lockedDefault))
    }

    @Test func mxpDisabledByDefault() {
        let (s, _) = (TelnetSession(delegate: FakeDelegateMXP()), ())
        #expect(!s.mxpEnabled)
    }
}

private final class FakeDelegateMXP: TelnetSessionDelegate {
    var writtenChunks: [[UInt8]] = []
    var allBytes: [UInt8] { writtenChunks.flatMap { $0 } }
    func telnetSession(_ session: TelnetSession, write data: [UInt8]) { writtenChunks.append(data) }
    func telnetSession(_ session: TelnetSession, log message: String) {}
    func telnetSessionMSSPData(_ session: TelnetSession) -> [(key: String, value: String)] { [] }
    func telnetSession(_ session: TelnetSession, gmcpReceived packet: GMCPPacket) {}
}

private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    firstIndexOfSubsequence(haystack, needle) != nil
}

private func firstIndexOfSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
        return start
    }
    return nil
}
