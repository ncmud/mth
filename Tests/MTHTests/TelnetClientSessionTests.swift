import Testing
@testable import MTHCore
@testable import MTHClient

private typealias TC = TelnetCommand
private typealias TO = TelnetOption
private typealias TS = TelnetSub

final class FakeClientDelegate: TelnetClientDelegate {
    var writtenChunks: [[UInt8]] = []
    var logMessages: [String] = []
    var gmcpMessages: [(module: String, json: String)] = []
    var msdpVariables: [(name: String, value: String)] = []
    var msspData: [[String: String]] = []
    var localEchoEnabled: Bool? = nil
    var promptCount = 0
    var bellCount = 0
    var gmcpNegotiatedCount = 0

    var allWrittenBytes: [UInt8] {
        writtenChunks.flatMap { $0 }
    }

    func write(data: [UInt8]) { writtenChunks.append(data) }
    func onLocalEchoChanged(enabled: Bool) { localEchoEnabled = enabled }
    func onGMCPNegotiated() { gmcpNegotiatedCount += 1 }
    func onGMCPReceived(module: String, json: String) { gmcpMessages.append((module, json)) }
    func onMSDPVariable(name: String, value: String) { msdpVariables.append((name, value)) }
    func onMSSPReceived(data: [String: String]) { msspData.append(data) }
    func onPromptReceived() { promptCount += 1 }
    func onBellReceived() { bellCount += 1 }
    func log(message: String) { logMessages.append(message) }
}

extension Array where Element == UInt8 {
    func containsSequence(_ seq: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard seq.count <= count else { return false }
        for i in 0...(count - seq.count) {
            if Array(self[i..<i + seq.count]) == seq { return true }
        }
        return false
    }
}

private func makeSession() -> (TelnetClientSession, FakeClientDelegate) {
    let d = FakeClientDelegate()
    let s = TelnetClientSession(delegate: d)
    return (s, d)
}

struct TelnetClientSessionTests {

    @Test func plainTextPassthrough() {
        let (s, _) = makeSession()
        let input: [UInt8] = Array("Hello, World!".utf8)
        let out = s.processInput(input)
        #expect(out == input)
    }

    @Test func emptyInput() {
        let (s, _) = makeSession()
        let out = s.processInput([])
        #expect(out.isEmpty)
    }

    @Test func iacIacProducesLiteralFF() {
        let (s, _) = makeSession()
        let out = s.processInput([0x41, 0xFF, 0xFF, 0x42])
        #expect(out == [0x41, 0xFF, 0x42])
    }

    @Test func serverWillGmcpRespondsDoGmcp() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        #expect(s.gmcpEnabled)
        #expect(d.allWrittenBytes == [TC.IAC, TC.DO, TO.GMCP])
    }

    @Test func serverSendsGmcpDataParsed() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        d.writtenChunks.removeAll()
        let payload: [UInt8] = Array("Char.Vitals {\"hp\":100,\"mana\":50}".utf8)
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.GMCP] + payload + [TC.IAC, TC.SE]
        _ = s.processInput(packet)
        #expect(d.gmcpMessages.count == 1)
        #expect(d.gmcpMessages[0].module == "Char.Vitals")
        #expect(d.gmcpMessages[0].json == "{\"hp\":100,\"mana\":50}")
    }

    @Test func gmcpModuleWithNoPayload() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.GMCP] + Array("Core.Ping".utf8) + [TC.IAC, TC.SE]
        _ = s.processInput(packet)
        #expect(d.gmcpMessages.count == 1)
        #expect(d.gmcpMessages[0].module == "Core.Ping")
        #expect(d.gmcpMessages[0].json == "")
    }

    @Test func sendGmcpToServer() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        d.writtenChunks.removeAll()
        s.sendGMCP(module: "core.hello", json: "{\"client\":\"MTH\"}")
        let expected: [UInt8] = [TC.IAC, TC.SB, TO.GMCP] + Array("core.hello {\"client\":\"MTH\"}".utf8) + [TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == expected)
    }

    @Test func sendGmcpWithoutNegotiationDoesNothing() {
        let (s, d) = makeSession()
        s.sendGMCP(module: "core.hello", json: "{}")
        #expect(d.writtenChunks.isEmpty)
    }

    #if canImport(CZlib)
    @Test func serverWillMccp2RespondsDoMccp2() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MCCP2])
        #expect(d.allWrittenBytes == [TC.IAC, TC.DO, TO.MCCP2])
    }

    @Test func serverSbMccp2StartsDecompression() throws {
        let (s, _) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MCCP2])
        let plaintext: [UInt8] = Array("Hello from server!".utf8)
        let deflater = try #require(DeflateStream())
        let compressed = try #require(deflater.compress(plaintext))
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE] + compressed
        let out = s.processInput(packet)
        #expect(s.isMCCP2Active)
        #expect(out == plaintext)
    }

    @Test func mccp2DecompressionAcrossMultiplePackets() throws {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MCCP2])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE])
        #expect(s.isMCCP2Active)
        let plaintext: [UInt8] = Array("Second packet".utf8)
        let deflater = try #require(DeflateStream())
        let compressed = try #require(deflater.compress(plaintext))
        let out = s.processInput(compressed)
        #expect(out == plaintext)
    }
    #endif

    @Test func serverWillEchoDisablesLocalEcho() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.ECHO])
        #expect(s.serverEcho)
        #expect(d.localEchoEnabled == false)
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.DO, TO.ECHO]))
    }

    @Test func serverWontEchoEnablesLocalEcho() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.ECHO])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.WONT, TO.ECHO])
        #expect(!s.serverEcho)
        #expect(d.localEchoEnabled == true)
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.DONT, TO.ECHO]))
    }

    @Test func serverDoTtypeRespondsWillTtype() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.DO, TO.TTYPE])
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.WILL, TO.TTYPE]))
    }

    @Test func serverSbTtypeSendRespondsWithTerminalType() {
        let (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        _ = s.processInput([TC.IAC, TC.DO, TO.TTYPE])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        let expected: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS] + Array("Wamdroid".utf8) + [TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == expected)
    }

    @Test func ttypeSecondRoundSends256Color() {
        let (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        _ = s.processInput([TC.IAC, TC.DO, TO.TTYPE])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        let expected: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS] + Array("Wamdroid-256color".utf8) + [TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == expected)
    }

    @Test func ttypeThirdRoundSendsMTTS() {
        let (s, d) = makeSession()
        s.terminalType = "Wamdroid"
        _ = s.processInput([TC.IAC, TC.DO, TO.TTYPE])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        d.writtenChunks.removeAll()
        _ = s.processInput([TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE])
        let expected: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS] + Array("MTTS 137".utf8) + [TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == expected)
    }

    @Test func serverDoNawsRespondsWillAndSendsSize() {
        let (s, d) = makeSession()
        s.windowWidth = 120
        s.windowHeight = 40
        _ = s.processInput([TC.IAC, TC.DO, TO.NAWS])
        let written = d.allWrittenBytes
        #expect(written.containsSequence([TC.IAC, TC.WILL, TO.NAWS]))
        #expect(written.containsSequence([TC.IAC, TC.SB, TO.NAWS, 0, 120, 0, 40, TC.IAC, TC.SE]))
    }

    @Test func sendWindowSizeUpdatesNaws() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.DO, TO.NAWS])
        d.writtenChunks.removeAll()
        s.sendWindowSize(width: 200, height: 50)
        let expected: [UInt8] = [TC.IAC, TC.SB, TO.NAWS, 0, 200, 0, 50, TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == expected)
    }

    @Test func sendWindowSizeBeforeNegotiationDoesNothing() {
        let (s, d) = makeSession()
        s.sendWindowSize(width: 120, height: 40)
        #expect(d.writtenChunks.isEmpty)
    }

    @Test func serverWillMsdpRespondsDo() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MSDP])
        #expect(s.msdpEnabled)
        #expect(d.allWrittenBytes == [TC.IAC, TC.DO, TO.MSDP])
    }

    @Test func serverSendsMsdpVariableUpdate() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MSDP])
        d.writtenChunks.removeAll()
        let MV: UInt8 = 1; let ML: UInt8 = 2
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.MSDP, MV] + Array("HEALTH".utf8) + [ML] + Array("100".utf8) + [TC.IAC, TC.SE]
        _ = s.processInput(packet)
        #expect(d.msdpVariables.count == 1)
        #expect(d.msdpVariables[0].name == "HEALTH")
        #expect(d.msdpVariables[0].value == "100")
    }

    @Test func serverEorTriggersPrompt() {
        let (s, d) = makeSession()
        let out = s.processInput(Array("HP: 100> ".utf8) + [TC.IAC, TC.EOR])
        #expect(out == Array("HP: 100> ".utf8))
        #expect(d.promptCount == 1)
    }

    @Test func serverGaTriggersPrompt() {
        let (s, d) = makeSession()
        let out = s.processInput(Array("HP: 100> ".utf8) + [TC.IAC, TC.GA])
        #expect(out == Array("HP: 100> ".utf8))
        #expect(d.promptCount == 1)
    }

    @Test func fragmentedIacSequenceReassembles() {
        let (s, d) = makeSession()
        let out1 = s.processInput([0x41, TC.IAC, TC.WILL])
        #expect(out1 == [0x41])
        let out2 = s.processInput([TO.GMCP, 0x42])
        #expect(out2 == [0x42])
        #expect(s.gmcpEnabled)
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.DO, TO.GMCP]))
    }

    @Test func fragmentedSubnegotiationReassembles() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        d.writtenChunks.removeAll()
        d.gmcpMessages.removeAll()
        let out1 = s.processInput([TC.IAC, TC.SB, TO.GMCP] + Array("Char.Name".utf8))
        #expect(out1.isEmpty)
        let out2 = s.processInput(Array(" \"Hero\"".utf8) + [TC.IAC, TC.SE])
        #expect(out2.isEmpty)
        #expect(d.gmcpMessages.count == 1)
        #expect(d.gmcpMessages[0].module == "Char.Name")
        #expect(d.gmcpMessages[0].json == "\"Hero\"")
    }

    @Test func unsupportedWillGetsDont() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, 99])
        #expect(d.allWrittenBytes == [TC.IAC, TC.DONT, 99])
    }

    @Test func unsupportedDoGetsWont() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.DO, 99])
        #expect(d.allWrittenBytes == [TC.IAC, TC.WONT, 99])
    }

    @Test func mixedTextAndTelnet() {
        let (s, _) = makeSession()
        let input: [UInt8] = Array("Welcome!".utf8) + [TC.IAC, TC.WILL, TO.ECHO] + Array(" Login:".utf8)
        let out = s.processInput(input)
        #expect(out == Array("Welcome! Login:".utf8))
        #expect(s.serverEcho)
    }

    @Test func multipleNegotiationsInOnePacket() {
        let (s, d) = makeSession()
        let input: [UInt8] = [TC.IAC, TC.WILL, TO.GMCP, TC.IAC, TC.WILL, TO.ECHO, TC.IAC, TC.WILL, TO.EOR]
        _ = s.processInput(input)
        #expect(s.gmcpEnabled)
        #expect(s.serverEcho)
        let written = d.allWrittenBytes
        #expect(written.containsSequence([TC.IAC, TC.DO, TO.GMCP]))
        #expect(written.containsSequence([TC.IAC, TC.DO, TO.ECHO]))
        #expect(written.containsSequence([TC.IAC, TC.DO, TO.EOR]))
    }

    @Test func serverWillSgaRespondsDo() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.SGA])
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.DO, TO.SGA]))
    }

    @Test func carriageReturnStripped() {
        let (s, _) = makeSession()
        let out = s.processInput([0x48, 0x69, 0x0D, 0x0A])
        #expect(out == [0x48, 0x69, 0x0A])
    }

    @Test func loneCrStripped() {
        let (s, _) = makeSession()
        let out = s.processInput([0x41, 0x0D, 0x42])
        #expect(out == [0x41, 0x42])
    }

    @Test func bellStrippedAndDelegateNotified() {
        let (s, d) = makeSession()
        let out = s.processInput([0x41, 0x07, 0x42])
        #expect(out == [0x41, 0x42])
        #expect(d.bellCount == 1)
    }

    @Test func multipleBells() {
        let (s, d) = makeSession()
        _ = s.processInput([0x07, 0x07, 0x07])
        #expect(d.bellCount == 3)
    }

    @Test func gmcpNegotiatedCallbackFires() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        #expect(d.gmcpNegotiatedCount == 1)
    }

    @Test func gmcpNegotiatedCallbackFiresOnlyOnce() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        _ = s.processInput([TC.IAC, TC.WILL, TO.GMCP])
        #expect(d.gmcpNegotiatedCount == 2)
    }

    @Test func serverWillMsspRespondsDo() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MSSP])
        #expect(s.msspEnabled)
        #expect(d.allWrittenBytes == [TC.IAC, TC.DO, TO.MSSP])
    }

    @Test func serverSendsMsspData() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MSSP])
        d.writtenChunks.removeAll()
        let MV: UInt8 = 1; let ML: UInt8 = 2
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.MSSP, MV] + Array("NAME".utf8) +
            [ML] + Array("TestMUD".utf8) +
            [MV] + Array("PLAYERS".utf8) +
            [ML] + Array("42".utf8) +
            [TC.IAC, TC.SE]
        _ = s.processInput(packet)
        #expect(d.msspData.count == 1)
        #expect(d.msspData[0]["NAME"] == "TestMUD")
        #expect(d.msspData[0]["PLAYERS"] == "42")
    }

    @Test func msspWithMultipleValues() {
        let (s, d) = makeSession()
        _ = s.processInput([TC.IAC, TC.WILL, TO.MSSP])
        d.writtenChunks.removeAll()
        let MV: UInt8 = 1; let ML: UInt8 = 2
        // MSSP_VAR "GENRE" MSSP_VAL "Fantasy" MSSP_VAL "Adventure" — last value wins
        let packet: [UInt8] = [TC.IAC, TC.SB, TO.MSSP, MV] + Array("GENRE".utf8) +
            [ML] + Array("Fantasy".utf8) +
            [ML] + Array("Adventure".utf8) +
            [TC.IAC, TC.SE]
        _ = s.processInput(packet)
        #expect(d.msspData.count == 1)
        #expect(d.msspData[0]["GENRE"] == "Adventure")
    }

    // MARK: - Nanvaent Replay Tests

    /// Captured bytes from nanvaent.org:23 for replay testing.
    /// These exercise MCCP2 with standard zlib (windowBits=15, header 78 DA),
    /// embedded telnet commands in compressed stream, and unknown option handling.
    private enum Nanvaent {
        // Round 1: IAC DO TTYPE
        static let round1: [UInt8] = [0xFF, 0xFD, 0x18]

        // Round 2: DO NAWS, WILL MCCP2, DO MXP(91), WILL MSSP, WILL 93, DO NEW_ENVIRON
        static let round2: [UInt8] = [
            0xFF, 0xFD, 0x1F, 0xFF, 0xFB, 0x56, 0xFF, 0xFD, 0x5B, 0xFF, 0xFB, 0x46, 0xFF, 0xFB, 0x5D, 0xFF,
            0xFD, 0x27,
        ]

        // Round 3: SB TTYPE SEND IAC SE
        static let round3: [UInt8] = [0xFF, 0xFA, 0x18, 0x01, 0xFF, 0xF0]

        // Round 4: SB MCCP2 IAC SE (compression starts)
        static let round4: [UInt8] = [0xFF, 0xFA, 0x56, 0xFF, 0xF0]

        // Round 5: compressed data — MSSP subneg + unknown option SBs (standard zlib, 78 DA header)
        static let round5: [UInt8] = [
            0x78, 0xDA, 0xFA, 0xFF, 0xCB, 0x0D, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62, 0xF4, 0x73, 0xF4, 0x75,
            0x65, 0xF2, 0x4B, 0xCC, 0x2B, 0x4B, 0x4C, 0xCD, 0x2B, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62,
            0x0C, 0xF0, 0x71, 0x8C, 0x74, 0x0D, 0x0A, 0x66, 0xB2, 0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x62,
            0x0C, 0x0D, 0x08, 0xF1, 0x04, 0xCA, 0x18, 0x9A, 0x9B, 0x1B, 0x5A, 0x98, 0x5B, 0x9A, 0x1A, 0x1A,
            0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFA, 0xFF, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFA, 0xFF,
            0x2B, 0xF4, 0xF7, 0x07, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
        ]

        // Round 6: compressed banner text (370 bytes)
        static let round6: [UInt8] = [
            0xB4, 0x53, 0x3D, 0x6F, 0xC3, 0x20, 0x10, 0xDD, 0x2D, 0xF9, 0x3F, 0x9C, 0xB2, 0xA4, 0x1D, 0x12,
            0xF6, 0x48, 0x91, 0xDA, 0xC1, 0x5B, 0x87, 0x48, 0x55, 0x87, 0xAA, 0x54, 0x16, 0x49, 0x88, 0x4D,
            0x6B, 0x43, 0x64, 0x83, 0x2A, 0xFF, 0xFB, 0xDE, 0x61, 0x9C, 0x92, 0xC4, 0xAD, 0xBB, 0xE4, 0x84,
            0x6C, 0xEE, 0xE3, 0x3D, 0xB8, 0x07, 0xA4, 0x09, 0xBC, 0xAD, 0xD7, 0xEB, 0xC5, 0x99, 0x61, 0xE0,
            0x1D, 0xB2, 0x45, 0x2D, 0x54, 0x05, 0x2B, 0xD0, 0x81, 0xED, 0x61, 0x98, 0x2C, 0x4D, 0x53, 0xFC,
            0x82, 0x4A, 0x13, 0x24, 0x9C, 0x32, 0xC6, 0xFD, 0x6F, 0xBA, 0x92, 0x01, 0xF0, 0xEB, 0x68, 0x9E,
            0x4F, 0x22, 0x19, 0xAD, 0xC1, 0xC7, 0xE8, 0xA6, 0xA0, 0xAC, 0x5F, 0xF4, 0x12, 0x8B, 0x3E, 0x9B,
            0x80, 0x7A, 0xE4, 0x08, 0x96, 0xF5, 0xC8, 0x3C, 0x32, 0xEF, 0x84, 0x10, 0x16, 0xE4, 0xAC, 0x77,
            0x08, 0x1A, 0x65, 0x10, 0x78, 0x05, 0xF2, 0x86, 0x74, 0x77, 0x71, 0x62, 0x58, 0x97, 0xE6, 0xBC,
            0x77, 0x42, 0x13, 0xA7, 0x50, 0x0E, 0x43, 0x86, 0xE8, 0x91, 0x2A, 0xA2, 0xBE, 0x0F, 0x8D, 0x9D,
            0x38, 0xB9, 0xEF, 0x77, 0x80, 0x0D, 0x83, 0xE8, 0x4E, 0x21, 0xDA, 0xDE, 0x90, 0xF1, 0x9F, 0x0B,
            0xAE, 0x1F, 0x3E, 0x4E, 0x83, 0xF1, 0xBE, 0xA3, 0xC8, 0x89, 0x42, 0xD4, 0x6A, 0x9F, 0xA1, 0xFD,
            0xB1, 0x4B, 0x9E, 0x71, 0x9D, 0xE3, 0xB3, 0xE1, 0x91, 0xCE, 0xFF, 0xC3, 0x04, 0x54, 0xC0, 0xBC,
            0xB4, 0x12, 0xE6, 0x85, 0x93, 0xAD, 0x9D, 0x83, 0x3A, 0xFC, 0x71, 0xF7, 0xBC, 0x04, 0xCC, 0xDF,
            0xDC, 0xCE, 0x38, 0xF8, 0x70, 0xAD, 0x85, 0x2F, 0xA1, 0x2D, 0x58, 0x13, 0xC4, 0x65, 0x30, 0x02,
            0x22, 0x32, 0xC2, 0x54, 0xC6, 0x7C, 0x82, 0x68, 0x8C, 0xD3, 0xFB, 0xE5, 0xC4, 0x0D, 0xF6, 0xA7,
            0x15, 0x5E, 0x93, 0x95, 0x95, 0x96, 0x16, 0xCE, 0x9E, 0xDF, 0xA4, 0x95, 0xD6, 0x1E, 0x57, 0x8C,
            0xC5, 0x20, 0x76, 0x83, 0xC7, 0xFE, 0x6A, 0x5C, 0x03, 0x8D, 0x2A, 0x4A, 0xDB, 0x42, 0x2D, 0x3A,
            0xD8, 0x4A, 0xD8, 0xAB, 0x76, 0x57, 0x09, 0x55, 0x4B, 0x6C, 0x72, 0x53, 0x49, 0x81, 0xE2, 0xDA,
            0xEE, 0x28, 0x61, 0x56, 0xCA, 0xEA, 0x18, 0x6A, 0x67, 0x20, 0x0E, 0x56, 0x36, 0xA8, 0x48, 0xA1,
            0xF4, 0x32, 0x4D, 0x36, 0x4F, 0xD9, 0xE3, 0x73, 0x06, 0x8E, 0x6A, 0x4B, 0x3C, 0x8C, 0xAD, 0x2B,
            0xE6, 0xB0, 0x33, 0x75, 0x2D, 0xF4, 0x9E, 0xC4, 0xC5, 0x3A, 0xC0, 0x58, 0xEB, 0x65, 0x3F, 0x28,
            0xD4, 0x2F, 0x4D, 0x32, 0x4D, 0x0C, 0x1D, 0x6D, 0x40, 0x8B, 0x5A, 0xAE, 0xE0, 0x1B, 0x00, 0x00,
            0xFF, 0xFF,
        ]
    }

    #if canImport(CZlib)
    @Test func nanvaentNegotiationAndMCCP2() {
        let (s, d) = makeSession()
        s.terminalType = "Wammer"

        // Round 1: DO TTYPE
        _ = s.processInput(Nanvaent.round1)
        #expect(d.allWrittenBytes.containsSequence([TC.IAC, TC.WILL, TO.TTYPE]))

        // Round 2: DO NAWS, WILL MCCP2, DO MXP(91), WILL MSSP, WILL 93, DO NEW_ENVIRON
        d.writtenChunks.removeAll()
        _ = s.processInput(Nanvaent.round2)
        let r2 = d.allWrittenBytes
        #expect(r2.containsSequence([TC.IAC, TC.WILL, TO.NAWS]))       // WILL NAWS
        #expect(r2.containsSequence([TC.IAC, TC.DO, TO.MCCP2]))        // DO MCCP2
        #expect(r2.containsSequence([TC.IAC, TC.WONT, 91]))            // WONT MXP
        #expect(r2.containsSequence([TC.IAC, TC.DO, TO.MSSP]))         // DO MSSP
        #expect(r2.containsSequence([TC.IAC, TC.DONT, 93]))            // DONT unknown(93)
        #expect(r2.containsSequence([TC.IAC, TC.WONT, 39]))            // WONT NEW_ENVIRON

        // Round 3: SB TTYPE SEND
        d.writtenChunks.removeAll()
        _ = s.processInput(Nanvaent.round3)
        let ttypeResponse: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS] + Array("Wammer".utf8) + [TC.IAC, TC.SE]
        #expect(d.allWrittenBytes == ttypeResponse)

        // Round 4: SB MCCP2 (compression starts, no trailing data)
        d.writtenChunks.removeAll()
        _ = s.processInput(Nanvaent.round4)
        #expect(s.isMCCP2Active)

        // Round 5: compressed telnet data (MSSP + unknown SBs)
        let out5 = s.processInput(Nanvaent.round5)
        #expect(d.msspData.count == 1, "MSSP data should be received from compressed stream")
        #expect(d.msspData[0]["NAME"] == "Nanvaent")
        // Output should be empty (only telnet commands, no visible text)
        #expect(out5.isEmpty, "Round 5 should contain only telnet commands, no visible text")

        // Round 6: compressed banner text
        let out6 = s.processInput(Nanvaent.round6)
        let bannerText = String(decoding: out6, as: UTF8.self)
        #expect(!out6.isEmpty)
        #expect(bannerText.contains("Enter your name:"))
        #expect(bannerText.contains("nanvaent.org"))
    }

    @Test func nanvaentInflateStreamDirectly() throws {
        let inflater = try #require(InflateStream())

        let r5 = try #require(inflater.decompress(Nanvaent.round5))
        #expect(!r5.decompressed.isEmpty)

        let r6 = try #require(inflater.decompress(Nanvaent.round6))
        let text = String(decoding: r6.decompressed, as: UTF8.self)
        #expect(text.contains("nanvaent"))
    }

    @Test func nanvaentCombinedMCCP2Packet() {
        // Test the case where MCCP2 SB and compressed data arrive in one packet
        let (s, d) = makeSession()
        s.terminalType = "Wammer"

        _ = s.processInput(Nanvaent.round1)
        _ = s.processInput(Nanvaent.round2)
        _ = s.processInput(Nanvaent.round3)

        // Combine rounds 4+5 into one packet (MCCP2 SB + compressed data together)
        let combined = Nanvaent.round4 + Nanvaent.round5
        _ = s.processInput(combined)
        #expect(s.isMCCP2Active)
        #expect(d.msspData.count == 1)
        #expect(d.msspData[0]["NAME"] == "Nanvaent")

        // Banner still arrives in next packet
        let out6 = s.processInput(Nanvaent.round6)
        let bannerText = String(decoding: out6, as: UTF8.self)
        #expect(bannerText.contains("Enter your name:"))
    }

    #endif
}
