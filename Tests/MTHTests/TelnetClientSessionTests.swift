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
}
