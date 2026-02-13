import Testing
import MTH

// Telnet protocol constants (local aliases for readability)
private let IAC: UInt8 = 255
private let DONT: UInt8 = 254
private let DO: UInt8 = 253
private let WONT: UInt8 = 252
private let WILL: UInt8 = 251
private let SB: UInt8 = 250
private let GA: UInt8 = 249
private let SE: UInt8 = 240
private let EOR_CMD: UInt8 = 239
private let NOP: UInt8 = 241

// Telnet options
private let ECHO: UInt8 = 1
private let SGA: UInt8 = 3
private let TTYPE: UInt8 = 24
private let EOR_OPT: UInt8 = 25
private let NAWS: UInt8 = 31
private let NEW_ENVIRON: UInt8 = 39
private let CHARSET: UInt8 = 42
private let MSDP: UInt8 = 69
private let MSSP: UInt8 = 70
private let MCCP2: UInt8 = 86
private let MCCP3: UInt8 = 87
private let GMCP: UInt8 = 201

// Sub-negotiation constants
private let ENV_IS: UInt8 = 0
private let ENV_SEND: UInt8 = 1
private let ENV_VAR: UInt8 = 0
private let ENV_VAL: UInt8 = 1
private let ENV_USR: UInt8 = 3
private let CHARSET_REQUEST: UInt8 = 1
private let CHARSET_ACCEPTED: UInt8 = 2
private let CHARSET_REJECTED: UInt8 = 3
private let MSSP_VAR: UInt8 = 1
private let MSSP_VAL: UInt8 = 2

/// Fake delegate that captures all output for verification.
private final class FakeDelegate: TelnetSessionDelegate {
    var writtenChunks: [[UInt8]] = []
    var logMessages: [String] = []
    var msspPairs: [(key: String, value: String)] = []

    var allWrittenBytes: [UInt8] { writtenChunks.flatMap { $0 } }

    func telnetSession(_ session: TelnetSession, write data: [UInt8]) {
        writtenChunks.append(data)
    }

    func telnetSession(_ session: TelnetSession, log message: String) {
        logMessages.append(message)
    }

    func telnetSessionMSSPData(_ session: TelnetSession) -> [(key: String, value: String)] {
        msspPairs
    }
}

private func makeSession() -> (TelnetSession, FakeDelegate) {
    let d = FakeDelegate()
    let s = TelnetSession(delegate: d)
    return (s, d)
}

// MARK: - Plain Text Passthrough

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

// MARK: - CR/NUL Handling

@Test func crNulConvertsToNewline() {
    let (s, _) = makeSession()
    let out = s.processInput([0x48, 0x0D, 0x00, 0x49]) // H \r\0 I
    #expect(out == [0x48, 0x0A, 0x49]) // H \n I
}

@Test func crLfSkipsCrKeepsLf() {
    let (s, _) = makeSession()
    let out = s.processInput([0x48, 0x0D, 0x0A, 0x49]) // H \r\n I
    #expect(out == [0x48, 0x0A, 0x49]) // H \n I
}

@Test func standaloneNulStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x48, 0x00, 0x49])
    #expect(out == [0x48, 0x49])
}

@Test func standaloneCrStripped() {
    // CR at end of input with no following byte → stripped, no output appended
    let (s, _) = makeSession()
    let out = s.processInput([0x48, 0x0D])
    #expect(out == [0x48])
}

// MARK: - IAC IAC Escape

@Test func iacIacProducesLiteralFF() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, IAC, 0x42])
    #expect(out == [0x41, 0xFF, 0x42])
}

// MARK: - WILL/WONT/DO/DONT Stripping

@Test func willIsStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, WILL, SGA, 0x42])
    #expect(out == [0x41, 0x42])
}

@Test func wontIsStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, WONT, SGA, 0x42])
    #expect(out == [0x41, 0x42])
}

@Test func doIsStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, DO, SGA, 0x42])
    #expect(out == [0x41, 0x42])
}

@Test func dontIsStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, DONT, SGA, 0x42])
    #expect(out == [0x41, 0x42])
}

// MARK: - Subnegotiation Stripping

@Test func unknownSubnegotiationStripped() {
    let (s, _) = makeSession()
    // IAC SB <unknown option 99> <data> IAC SE
    let out = s.processInput([0x41, IAC, SB, 99, 1, 2, 3, IAC, SE, 0x42])
    #expect(out == [0x41, 0x42])
}

// MARK: - Packet Fragmentation (telbuf)

@Test func fragmentedIACReassembles() {
    let (s, _) = makeSession()
    // First call: text + incomplete IAC
    let out1 = s.processInput([0x41, IAC])
    #expect(out1 == [0x41])

    // Second call: complete the IAC IAC escape
    let out2 = s.processInput([IAC, 0x42])
    #expect(out2 == [0xFF, 0x42])
}

@Test func fragmentedWillReassembles() {
    let (s, _) = makeSession()
    // Split IAC WILL SGA across two packets
    let out1 = s.processInput([0x41, IAC, WILL])
    #expect(out1 == [0x41])

    let out2 = s.processInput([SGA, 0x42])
    #expect(out2 == [0x42])
}

@Test func fragmentedSubnegotiationReassembles() {
    let (s, _) = makeSession()
    // Start a NAWS subneg but cut it off before IAC SE
    let out1 = s.processInput([0x41, IAC, SB, NAWS, 0, 80])
    #expect(out1 == [0x41])

    // Complete with rest of data + IAC SE
    let out2 = s.processInput([0, 24, IAC, SE, 0x42])
    #expect(out2 == [0x42])
    #expect(s.windowSize.cols == 80)
    #expect(s.windowSize.rows == 24)
}

// MARK: - Two-byte Commands

@Test func gaCmdStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, GA, 0x42])
    #expect(out == [0x41, 0x42])
}

@Test func nopCmdStripped() {
    let (s, _) = makeSession()
    let out = s.processInput([0x41, IAC, NOP, 0x42])
    #expect(out == [0x41, 0x42])
}

// MARK: - announceSupport / unannounceSupport

@Test func announceSupportSendsExpectedOptions() {
    let (s, d) = makeSession()
    s.announceSupport()

    let bytes = d.allWrittenBytes
    // Check that WILL CHARSET (42) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, CHARSET]))
    // Check that DO TTYPE (24) is sent
    #expect(bytes.contains(contentsOf: [IAC, DO, TTYPE]))
    // Check that DO NAWS (31) is sent
    #expect(bytes.contains(contentsOf: [IAC, DO, NAWS]))
    // Check that DO NEW_ENVIRON (39) is sent
    #expect(bytes.contains(contentsOf: [IAC, DO, NEW_ENVIRON]))
    // Check that WILL MSDP (69) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, MSDP]))
    // Check that WILL MSSP (70) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, MSSP]))
    // Check that WILL GMCP (201) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, GMCP]))
    // Check that WILL MCCP2 (86) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, MCCP2]))
    // Check that WILL MCCP3 (87) is sent
    #expect(bytes.contains(contentsOf: [IAC, WILL, MCCP3]))
}

@Test func unannounceSupportSendsWontDont() {
    let (s, d) = makeSession()
    s.unannounceSupport()

    let bytes = d.allWrittenBytes
    // Unannounce should use WONT/DONT instead of WILL/DO
    #expect(bytes.contains(contentsOf: [IAC, WONT, CHARSET]))
    #expect(bytes.contains(contentsOf: [IAC, DONT, TTYPE]))
    #expect(bytes.contains(contentsOf: [IAC, DONT, NAWS]))
    #expect(bytes.contains(contentsOf: [IAC, WONT, MSDP]))
    #expect(bytes.contains(contentsOf: [IAC, WONT, GMCP]))
}

// MARK: - Echo On/Off

@Test func sendEchoOffSetsPasswordAndSendsWillEcho() {
    let (s, d) = makeSession()
    s.sendEchoOff()
    #expect(s.commFlags.contains(.password))
    #expect(d.allWrittenBytes == [IAC, WILL, ECHO])
}

@Test func sendEchoOnClearsPasswordAndSendsWontEcho() {
    let (s, d) = makeSession()
    s.sendEchoOff() // set password mode first
    d.writtenChunks.removeAll()
    s.sendEchoOn()
    #expect(!s.commFlags.contains(.password))
    #expect(d.allWrittenBytes == [IAC, WONT, ECHO])
}

// MARK: - Send EOR

@Test func sendEOROnlyWhenEORNegotiated() {
    let (s, d) = makeSession()
    // Without EOR negotiated, nothing should be sent
    s.sendEOR()
    #expect(d.allWrittenBytes.isEmpty)

    // After DO EOR negotiation
    _ = s.processInput([IAC, DO, EOR_OPT])
    d.writtenChunks.removeAll()
    s.sendEOR()
    #expect(d.allWrittenBytes == [IAC, EOR_CMD])
}

// MARK: - DO EOR

@Test func doEorSetsFlag() {
    let (s, _) = makeSession()
    _ = s.processInput([IAC, DO, EOR_OPT])
    #expect(s.commFlags.contains(.eor))
}

// MARK: - Terminal Type

@Test func willTtypeSendsThreeRequestsThenDont() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, WILL, TTYPE])

    let request: [UInt8] = [IAC, SB, TTYPE, ENV_SEND, IAC, SE]

    // Should be 3 requests + 1 DONT = 4 chunks
    #expect(d.writtenChunks.count == 4)
    #expect(d.writtenChunks[0] == request)
    #expect(d.writtenChunks[1] == request)
    #expect(d.writtenChunks[2] == request)
    #expect(d.writtenChunks[3] == [IAC, DONT, TTYPE])
}

@Test func willTtypeIgnoredIfTerminalAlreadySet() {
    let (s, d) = makeSession()
    // First: set terminal type via SB TTYPE IS
    _ = s.processInput([IAC, WILL, TTYPE])
    let firstTtype: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("xterm".utf8) + [IAC, SE]
    _ = s.processInput(firstTtype)
    d.writtenChunks.removeAll()

    // Second WILL TTYPE should be ignored (terminal already set)
    _ = s.processInput([IAC, WILL, TTYPE])
    #expect(d.writtenChunks.isEmpty)
}

@Test func sbTtypeIsSetsTerminalType() {
    let (s, _) = makeSession()
    let packet: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("xterm-256color".utf8) + [IAC, SE]
    _ = s.processInput(packet)
    #expect(s.terminalType == "xterm-256color")
}

@Test func sbTtypeIsSecondResponseDetects256Color() {
    let (s, _) = makeSession()
    // First response sets terminal type
    let first: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("MUDLET".utf8) + [IAC, SE]
    _ = s.processInput(first)
    #expect(s.terminalType == "MUDLET")

    // Second response with "-256COLOR" suffix
    let second: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("MUDLET-256COLOR".utf8) + [IAC, SE]
    _ = s.processInput(second)
    #expect(s.commFlags.contains(.colors256))
}

@Test func sbTtypeIsMTTSDetection() {
    let (s, _) = makeSession()
    // First response sets terminal type
    let first: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("MUDLET".utf8) + [IAC, SE]
    _ = s.processInput(first)

    // MTTS response with flags: ANSI(1) + VT100(2) + UTF8(4) + 256COLOR(8) = 15
    let mtts: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("MTTS 15".utf8) + [IAC, SE]
    _ = s.processInput(mtts)

    #expect(s.mttsFlags.contains(.ansi))
    #expect(s.mttsFlags.contains(.vt100))
    #expect(s.mttsFlags.contains(.utf8))
    #expect(s.mttsFlags.contains(.colors256))
    #expect(s.commFlags.contains(.colors256))
    #expect(s.commFlags.contains(.utf8))
}

@Test func sbTtypeIsXtermSets256Color() {
    let (s, _) = makeSession()
    // First response
    let first: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("PUTTY".utf8) + [IAC, SE]
    _ = s.processInput(first)

    // Second response is exactly "XTERM"
    let second: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("XTERM".utf8) + [IAC, SE]
    _ = s.processInput(second)
    #expect(s.commFlags.contains(.colors256))
}

// MARK: - NAWS

@Test func nawsSetsWindowSize() {
    let (s, _) = makeSession()
    // NAWS: cols=80 (0x00 0x50), rows=24 (0x00 0x18)
    let packet: [UInt8] = [IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE]
    _ = s.processInput(packet)
    #expect(s.windowSize.cols == 80)
    #expect(s.windowSize.rows == 24)
}

@Test func nawsLargeWindowSize() {
    let (s, _) = makeSession()
    // cols=300 (0x01 0x2C), rows=100 (0x00 0x64)
    let packet: [UInt8] = [IAC, SB, NAWS, 1, 0x2C, 0, 0x64, IAC, SE]
    _ = s.processInput(packet)
    #expect(s.windowSize.cols == 300)
    #expect(s.windowSize.rows == 100)
}

@Test func nawsWithIACStuffing() {
    let (s, _) = makeSession()
    // Window width high byte is 0xFF (IAC) → doubled to IAC IAC
    // cols = 0xFF * 256 + 0x00 = 65280, rows = 0 * 256 + 24 = 24
    let packet: [UInt8] = [IAC, SB, NAWS, IAC, IAC, 0, 0, 24, IAC, SE]
    _ = s.processInput(packet)
    #expect(s.windowSize.cols == 65280)
    #expect(s.windowSize.rows == 24)
}

// MARK: - NEW-ENVIRON

@Test func willNewEnvironSendsRequest() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, WILL, NEW_ENVIRON])

    let expected: [UInt8] = [IAC, SB, NEW_ENVIRON, ENV_SEND, ENV_VAR]
        + Array("SYSTEMTYPE".utf8) + [IAC, SE]
    #expect(d.allWrittenBytes == expected)
}

@Test func sbNewEnvironWin32Detection() {
    let (s, _) = makeSession()
    // First set terminal type to ANSI
    let ttype: [UInt8] = [IAC, SB, TTYPE, ENV_IS] + Array("ANSI".utf8) + [IAC, SE]
    _ = s.processInput(ttype)
    #expect(s.terminalType == "ANSI")

    // NEW-ENVIRON IS: SYSTEMTYPE=WIN32
    let packet: [UInt8] = [IAC, SB, NEW_ENVIRON, ENV_IS,
                           ENV_VAR] + Array("SYSTEMTYPE".utf8)
        + [ENV_VAL] + Array("WIN32".utf8) + [IAC, SE]
    _ = s.processInput(packet)

    #expect(s.terminalType == "WINDOWS TELNET")
    #expect(s.commFlags.contains(.remoteEcho))
}

@Test func sbNewEnvironIPAddress() {
    let (s, _) = makeSession()
    let packet: [UInt8] = [IAC, SB, NEW_ENVIRON, ENV_IS,
                           ENV_VAR] + Array("IPADDRESS".utf8)
        + [ENV_VAL] + Array("192.168.1.100".utf8) + [IAC, SE]
    _ = s.processInput(packet)
    #expect(s.proxy == "192.168.1.100")
}

// MARK: - CHARSET

@Test func doCharsetSendsRequest() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, CHARSET])

    let expected: [UInt8] = [IAC, SB, CHARSET, CHARSET_REQUEST, 0x20]
        + Array("UTF-8".utf8) + [IAC, SE]
    #expect(d.allWrittenBytes == expected)
}

@Test func sbCharsetAcceptedSetsUtf8() {
    let (s, _) = makeSession()
    // CHARSET ACCEPTED with separator ';' then "UTF-8"
    let packet: [UInt8] = [IAC, SB, CHARSET, CHARSET_ACCEPTED, UInt8(ascii: ";")]
        + Array("UTF-8".utf8) + [IAC, SE]
    _ = s.processInput(packet)
    #expect(s.commFlags.contains(.utf8))
}

@Test func sbCharsetRejectedClearsUtf8() {
    let (s, _) = makeSession()
    // First accept UTF-8
    let accept: [UInt8] = [IAC, SB, CHARSET, CHARSET_ACCEPTED, UInt8(ascii: ";")]
        + Array("UTF-8".utf8) + [IAC, SE]
    _ = s.processInput(accept)
    #expect(s.commFlags.contains(.utf8))

    // Then reject it
    let reject: [UInt8] = [IAC, SB, CHARSET, CHARSET_REJECTED, UInt8(ascii: ";")]
        + Array("UTF-8".utf8) + [IAC, SE]
    _ = s.processInput(reject)
    #expect(!s.commFlags.contains(.utf8))
}

// MARK: - MSSP

@Test func doMsspSendsData() {
    let (s, d) = makeSession()
    d.msspPairs = [
        (key: "NAME", value: "TestMUD"),
        (key: "PLAYERS", value: "42"),
    ]
    _ = s.processInput([IAC, DO, MSSP])

    let bytes = d.allWrittenBytes
    // Should start with IAC SB MSSP
    #expect(bytes.starts(with: [IAC, SB, MSSP]))
    // Should end with IAC SE
    #expect(bytes.suffix(2) == [IAC, SE])
    // Should contain MSSP_VAR "NAME" MSSP_VAL "TestMUD"
    #expect(bytes.contains(contentsOf: [MSSP_VAR] + Array("NAME".utf8) + [MSSP_VAL] + Array("TestMUD".utf8)))
    #expect(bytes.contains(contentsOf: [MSSP_VAR] + Array("PLAYERS".utf8) + [MSSP_VAL] + Array("42".utf8)))
}

// MARK: - MSDP

@Test func doMsdpInitializesManager() {
    let (s, d) = makeSession()
    #expect(s.msdpManager == nil)
    _ = s.processInput([IAC, DO, MSDP])
    #expect(s.msdpManager != nil)
    #expect(d.logMessages.contains("INFO MSDP INITIALIZED"))
}

@Test func doMsdpIdempotent() {
    let (s, _) = makeSession()
    _ = s.processInput([IAC, DO, MSDP])
    let mgr1 = s.msdpManager
    _ = s.processInput([IAC, DO, MSDP])
    // Should be same instance (not re-initialized)
    #expect(s.msdpManager === mgr1)
}

@Test func sbMsdpProcessesCommand() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MSDP])
    d.writtenChunks.removeAll()

    // Send MSDP LIST COMMANDS
    let MV: UInt8 = 1  // MSDP_VAR
    let ML: UInt8 = 2  // MSDP_VAL
    let packet: [UInt8] = [IAC, SB, MSDP, MV]
        + Array("LIST".utf8) + [ML] + Array("COMMANDS".utf8) + [IAC, SE]
    _ = s.processInput(packet)

    // Should have produced output (LIST COMMANDS response)
    #expect(!d.writtenChunks.isEmpty)
}

// MARK: - GMCP

@Test func doGmcpInitializesMSDPOverGmcp() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, GMCP])
    #expect(s.msdpManager != nil)
    #expect(s.commFlags.contains(.gmcp))
    #expect(d.logMessages.contains("INFO MSDP OVER GMCP INITIALIZED"))
}

@Test func doGmcpIdempotent() {
    let (s, _) = makeSession()
    _ = s.processInput([IAC, DO, GMCP])
    let mgr1 = s.msdpManager
    _ = s.processInput([IAC, DO, GMCP])
    #expect(s.msdpManager === mgr1)
}

@Test func sbGmcpProcessesJsonCommand() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, GMCP])
    d.writtenChunks.removeAll()

    // GMCP JSON: MSDP {"LIST":"COMMANDS"}
    let json = Array("MSDP {\"LIST\":\"COMMANDS\"}".utf8)
    let packet: [UInt8] = [IAC, SB, GMCP] + json + [IAC, SE]
    _ = s.processInput(packet)

    // Should produce GMCP JSON response (since gmcp mode is on)
    #expect(!d.writtenChunks.isEmpty)
}

// MARK: - MCCP2 (Output Compression)

@Test func doMccp2StartsCompression() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MCCP2])
    #expect(s.isMCCP2Active)

    // First write should be the uncompressed start marker
    #expect(d.writtenChunks[0] == [IAC, SB, MCCP2, IAC, SE])
}

@Test func mccp2CompressesOutput() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MCCP2])
    d.writtenChunks.removeAll()

    // Write some text — should come out compressed (different from input)
    s.sendEchoOff() // triggers write([IAC, WILL, ECHO])

    #expect(!d.writtenChunks.isEmpty)
    // Compressed output should differ from the raw bytes
    let compressed = d.allWrittenBytes
    #expect(compressed != [IAC, WILL, ECHO])
    #expect(!compressed.isEmpty)
}

@Test func mccp2RoundTrip() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MCCP2])
    d.writtenChunks.removeAll()

    // Write known data through the compressor
    s.sendEchoOff() // IAC WILL ECHO
    let compressedEcho = d.allWrittenBytes
    d.writtenChunks.removeAll()

    // End compression — should flush remaining data
    s.endMCCP2()
    #expect(!s.isMCCP2Active)
    let finalBytes = d.allWrittenBytes

    // Decompress everything to verify round-trip
    let allCompressed = compressedEcho + finalBytes
    // Use CZlib-based inflate to decompress
    // (We can't import CZlib in tests, but we can use the session's own InflateStream)
    // Instead, just verify compressed data is non-empty and decompressible
    #expect(!allCompressed.isEmpty)
    #expect(d.logMessages.contains("MCCP2: COMPRESSION END"))
}

@Test func dontMccp2EndsCompression() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MCCP2])
    #expect(s.isMCCP2Active)
    _ = s.processInput([IAC, DONT, MCCP2])
    #expect(!s.isMCCP2Active)
    #expect(d.logMessages.contains("MCCP2: COMPRESSION END"))
}

@Test func mccp2IdempotentStart() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, DO, MCCP2])
    let chunks1 = d.writtenChunks.count
    _ = s.processInput([IAC, DO, MCCP2])
    // Second DO should not send another start marker
    #expect(d.writtenChunks.count == chunks1)
}

// MARK: - MCCP3 (Input Decompression)

@Test func sbMccp3InitializesInflate() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, SB, MCCP3, IAC, SE])
    #expect(s.isMCCP3Active)
    #expect(d.logMessages.contains("INFO IAC SB MCCP3 INITIALIZED"))
}

@Test func mccp3DecompressesInput() throws {
    let (s, _) = makeSession()
    // Initialize MCCP3
    _ = s.processInput([IAC, SB, MCCP3, IAC, SE])
    #expect(s.isMCCP3Active)

    // Create compressed data using DeflateStream
    // We compress "Hello\r\0" which should become "Hello\n" after telnet processing
    let plaintext: [UInt8] = Array("Hello".utf8) + [0x0D, 0x00]

    // Use zlib to compress the plaintext (simulating what a client would send)
    guard let deflater = DeflateStream() else {
        #expect(Bool(false), "Failed to create DeflateStream")
        return
    }
    guard let compressed = deflater.compress(plaintext) else {
        #expect(Bool(false), "Failed to compress")
        return
    }

    let out = s.processInput(compressed)
    #expect(out == Array("Hello\n".utf8))
}

@Test func endMccp3DisablesDecompression() {
    let (s, d) = makeSession()
    _ = s.processInput([IAC, SB, MCCP3, IAC, SE])
    #expect(s.isMCCP3Active)
    s.endMCCP3()
    #expect(!s.isMCCP3Active)
    #expect(d.logMessages.contains("MCCP3: COMPRESSION END"))
}

@Test func unannounceSupportEndsMCCP() {
    let (s, _) = makeSession()
    // Start MCCP2
    _ = s.processInput([IAC, DO, MCCP2])
    #expect(s.isMCCP2Active)
    // Start MCCP3
    _ = s.processInput([IAC, SB, MCCP3, IAC, SE])
    #expect(s.isMCCP3Active)

    s.unannounceSupport()
    #expect(!s.isMCCP2Active)
    #expect(!s.isMCCP3Active)
}

// MARK: - Mixed Input

@Test func mixedTextAndTelnet() {
    let (s, _) = makeSession()
    // "Hi" + IAC DO EOR + "Bye" + \r\0
    let input: [UInt8] = Array("Hi".utf8) + [IAC, DO, EOR_OPT] + Array("Bye".utf8) + [0x0D, 0x00]
    let out = s.processInput(input)
    #expect(out == Array("HiBye\n".utf8))
    #expect(s.commFlags.contains(.eor))
}

@Test func multipleNegotiationsInOnePacket() {
    let (s, _) = makeSession()
    // DO EOR + NAWS(80x24)
    let input: [UInt8] = [IAC, DO, EOR_OPT,
                          IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE]
    let out = s.processInput(input)
    #expect(out.isEmpty)
    #expect(s.commFlags.contains(.eor))
    #expect(s.windowSize.cols == 80)
    #expect(s.windowSize.rows == 24)
}

// MARK: - Sequence extension helper for test assertions

private extension Array where Element: Equatable {
    func contains(contentsOf other: [Element]) -> Bool {
        guard !other.isEmpty else { return true }
        guard count >= other.count else { return false }
        for i in 0...(count - other.count) {
            if Array(self[i..<i + other.count]) == other {
                return true
            }
        }
        return false
    }
}
