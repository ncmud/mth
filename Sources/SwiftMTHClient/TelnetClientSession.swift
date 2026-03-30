import MTHCore

private typealias TC = TelnetCommand
private typealias TO = TelnetOption
private typealias TS = TelnetSub

public final class TelnetClientSession {

    // MARK: - Public State

    public weak var delegate: (any TelnetClientDelegate)?
    public var terminalType: String
    public var windowWidth: Int
    public var windowHeight: Int
    public let mttsFlags: Int

    #if canImport(CZlib)
    public var isMCCP2Active: Bool { mccp2 != nil }
    #else
    public var isMCCP2Active: Bool { false }
    #endif

    public private(set) var serverEcho: Bool = false
    public private(set) var gmcpEnabled: Bool = false
    public private(set) var msdpEnabled: Bool = false
    public private(set) var msspEnabled: Bool = false

    // MARK: - Private State

    private var telbuf: [UInt8] = []
    private var serverOptions: Set<UInt8> = []
    private var clientOptions: Set<UInt8> = []
    private var ttypeRound: Int = 0

    #if canImport(CZlib)
    private var mccp2: InflateStream?
    private var mccp2Starting: Bool = false
    #endif

    // MARK: - Init

    public init(
        delegate: (any TelnetClientDelegate)? = nil,
        terminalType: String = "MTH",
        windowWidth: Int = 80,
        windowHeight: Int = 24,
        mttsFlags: Int = 137
    ) {
        self.delegate = delegate
        self.terminalType = terminalType
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.mttsFlags = mttsFlags
    }

    // MARK: - Public API

    public func sendWindowSize(width: Int? = nil, height: Int? = nil) {
        if let width { windowWidth = width }
        if let height { windowHeight = height }
        if clientOptions.contains(TO.NAWS) {
            sendNawsPacket()
        }
    }

    public func sendGMCP(module: String, json: String) {
        guard gmcpEnabled else { return }
        var packet: [UInt8] = [TC.IAC, TC.SB, TO.GMCP]
        packet.append(contentsOf: module.utf8)
        packet.append(UInt8(ascii: " "))
        packet.append(contentsOf: json.utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    // MARK: - Input Processing

    public func processInput(_ src: [UInt8]) -> [UInt8] {
        var input = src

        #if canImport(CZlib)
        if let inflater = mccp2 {
            guard let result = inflater.decompress(input) else {
                log("MCCP2: Decompression error, disabling MCCP2.")
                mccp2 = nil
                return []
            }
            if result.finished {
                log("MCCP2: Compression stream ended.")
                mccp2 = nil
                input = result.decompressed + result.unconsumedInput
            } else {
                input = result.decompressed
            }
        }
        #endif

        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        if !telbuf.isEmpty {
            telbuf.append(contentsOf: input)
            input = telbuf
            telbuf = []
        }

        var i = 0
        while i < input.count {
            switch input[i] {
            case TC.IAC:
                let remaining = input.count - i
                let (skip, matched) = dispatchTelopt(input, at: i, remaining: remaining)

                if !matched && remaining > 1 {
                    let genericSkip = handleGenericTelnet(input, at: i, remaining: remaining, out: &out)
                    if genericSkip <= remaining {
                        i += genericSkip
                    } else {
                        telbuf = Array(input[i...])
                        return out
                    }
                } else if skip <= remaining {
                    i += skip
                    #if canImport(CZlib)
                    if mccp2Starting {
                        mccp2Starting = false
                        if i < input.count {
                            let compressed = Array(input[i...])
                            let decompressed = processInput(compressed)
                            out.append(contentsOf: decompressed)
                            return out
                        }
                    }
                    #endif
                } else {
                    telbuf = Array(input[i...])
                    return out
                }

            case 0x0D:
                i += 1

            case 0x07:
                delegate?.onBellReceived()
                i += 1

            default:
                out.append(input[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - Telopt Dispatch

    private struct TeloptPattern {
        let pattern: [UInt8]
        let handler: (TelnetClientSession, [UInt8], Int, Int) -> Int
    }

    private func dispatchTelopt(_ src: [UInt8], at i: Int, remaining: Int) -> (Int, Bool) {
        for entry in teloptPatterns {
            if remaining < entry.pattern.count {
                let available = src[i..<i + remaining]
                if available.elementsEqual(entry.pattern.prefix(remaining)) {
                    return (entry.pattern.count, true)
                }
            } else {
                let slice = src[i..<i + entry.pattern.count]
                if slice.elementsEqual(entry.pattern) {
                    let skip = entry.handler(self, src, i, remaining)
                    return (skip, true)
                }
            }
        }
        return (2, false)
    }

    private lazy var teloptPatterns: [TeloptPattern] = buildTeloptPatterns()

    private func buildTeloptPatterns() -> [TeloptPattern] {
        var patterns: [TeloptPattern] = [
            // GMCP
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.GMCP],
                          handler: { s, _, _, _ in s.processWillGmcp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.GMCP],
                          handler: { s, src, i, n in s.processSbGmcp(src, at: i, srclen: n) }),

            // MSDP
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.MSDP],
                          handler: { s, _, _, _ in s.processWillMsdp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MSDP],
                          handler: { s, src, i, n in s.processSbMsdp(src, at: i, srclen: n) }),

            // MSSP
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.MSSP],
                          handler: { s, _, _, _ in s.processWillMssp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MSSP],
                          handler: { s, src, i, n in s.processSbMssp(src, at: i, srclen: n) }),

            // Echo
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.ECHO],
                          handler: { s, _, _, _ in s.processWillEcho(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.WONT, TO.ECHO],
                          handler: { s, _, _, _ in s.processWontEcho(); return 3 }),

            // EOR
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.EOR],
                          handler: { s, _, _, _ in s.processWillEor(); return 3 }),

            // SGA
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.SGA],
                          handler: { s, _, _, _ in s.processWillSga(); return 3 }),

            // TTYPE
            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.TTYPE],
                          handler: { s, _, _, _ in s.processDoTtype(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE],
                          handler: { s, _, _, _ in s.processSbTtypeSend(); return 6 }),

            // NAWS
            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.NAWS],
                          handler: { s, _, _, _ in s.processDoNaws(); return 3 }),

            // MCCP1 (option 85) uses a non-standard SB terminator: IAC SB 85 WILL SE
            // where SE appears without a preceding IAC. Skip the 5-byte start sequence.
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MCCP1, TC.WILL, TC.SE],
                          handler: { _, _, _, _ in return 5 }),

            // Prompt markers
            TeloptPattern(pattern: [TC.IAC, TC.EOR],
                          handler: { s, _, _, _ in s.delegate?.onPromptReceived(); return 2 }),
            TeloptPattern(pattern: [TC.IAC, TC.GA],
                          handler: { s, _, _, _ in s.delegate?.onPromptReceived(); return 2 }),
        ]

        #if canImport(CZlib)
        patterns += [
            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.MCCP2],
                          handler: { s, _, _, _ in s.processWillMccp2(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE],
                          handler: { s, _, _, _ in s.processSbMccp2(); return 5 }),
        ]
        #endif

        return patterns
    }

    private func handleGenericTelnet(_ src: [UInt8], at i: Int, remaining: Int, out: inout [UInt8]) -> Int {
        guard remaining > 1 else { return remaining + 1 }

        switch src[i + 1] {
        case TC.WILL:
            if remaining < 3 { return remaining + 1 }
            write([TC.IAC, TC.DONT, src[i + 2]])
            return 3

        case TC.DO:
            if remaining < 3 { return remaining + 1 }
            write([TC.IAC, TC.WONT, src[i + 2]])
            return 3

        case TC.WONT, TC.DONT:
            return 3

        case TC.SB:
            return skipSB(src, at: i, srclen: remaining)

        case TC.IAC:
            out.append(TC.IAC)
            return 2

        default:
            if TelnetCommand.isCommand(src[i + 1]) {
                return 2
            } else {
                return 1
            }
        }
    }

    // MARK: - Subnegotiation Helpers

    private func skipSB(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let end = offset + srclen
        var j = offset + 1
        while j < end {
            if src[j] == TC.SE && j > offset && src[j - 1] == TC.IAC {
                return j - offset + 1
            }
            j += 1
        }
        return srclen + 1
    }

    // MARK: - Output

    private func write(_ data: [UInt8]) {
        delegate?.write(data: data)
    }

    private func log(_ message: String) {
        delegate?.log(message: message)
    }

    // MARK: - Handler: GMCP

    private func processWillGmcp() {
        gmcpEnabled = true
        serverOptions.insert(TO.GMCP)
        write([TC.IAC, TC.DO, TO.GMCP])
        delegate?.onGMCPNegotiated()
    }

    private func processSbGmcp(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        let payloadStart = offset + 3
        let payloadEnd = offset + sbLen - 2
        guard payloadEnd > payloadStart else { return sbLen }

        let payload = String(decoding: src[payloadStart..<payloadEnd], as: UTF8.self)
        if let spaceIdx = payload.firstIndex(of: " ") {
            delegate?.onGMCPReceived(
                module: String(payload[..<spaceIdx]),
                json: String(payload[payload.index(after: spaceIdx)...])
            )
        } else {
            delegate?.onGMCPReceived(module: payload, json: "")
        }
        return sbLen
    }

    // MARK: - Handler: MCCP2

    #if canImport(CZlib)
    private func processWillMccp2() {
        serverOptions.insert(TO.MCCP2)
        write([TC.IAC, TC.DO, TO.MCCP2])
    }

    private func processSbMccp2() {
        guard let stream = InflateStream() else {
            log("MCCP2: Failed to initialize inflate stream. InflateStream() returned nil.")
            return
        }
        mccp2 = stream
        mccp2Starting = true
        log("MCCP2: Decompression started.")
    }
    #endif

    // MARK: - Handler: MSDP

    private func processWillMsdp() {
        msdpEnabled = true
        serverOptions.insert(TO.MSDP)
        write([TC.IAC, TC.DO, TO.MSDP])
    }

    private func processSbMsdp(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        var varName = ""
        var j = offset + 3
        let end = offset + srclen

        while j < end && src[j] != TC.SE {
            switch src[j] {
            case 1: // MSDP_VAR
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] != 2 && src[j] != TC.IAC {
                    buf.append(src[j])
                    j += 1
                }
                varName = String(decoding: buf, as: UTF8.self)

            case 2: // MSDP_VAL
                j += 1
                var buf: [UInt8] = []
                var nest = 0
                while j < end && src[j] != TC.IAC {
                    if src[j] == 3 || src[j] == 5 { // TABLE_OPEN or ARRAY_OPEN
                        nest += 1
                    } else if src[j] == 4 || src[j] == 6 { // TABLE_CLOSE or ARRAY_CLOSE
                        nest -= 1
                    } else if nest == 0 && (src[j] == 1 || src[j] == 2) {
                        break
                    }
                    buf.append(src[j])
                    j += 1
                }
                let valStr = String(decoding: buf, as: UTF8.self)
                if nest == 0 && !varName.isEmpty {
                    delegate?.onMSDPVariable(name: varName, value: valStr)
                }

            default:
                j += 1
            }
        }
        return sbLen
    }

    // MARK: - Handler: MSSP

    private func processWillMssp() {
        msspEnabled = true
        serverOptions.insert(TO.MSSP)
        write([TC.IAC, TC.DO, TO.MSSP])
    }

    private func processSbMssp(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        var data: [String: String] = [:]
        var varName = ""
        var j = offset + 3
        let end = offset + srclen

        while j < end && src[j] != TC.SE {
            switch src[j] {
            case 1: // MSSP_VAR
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] != 1 && src[j] != 2 && src[j] != TC.IAC {
                    buf.append(src[j])
                    j += 1
                }
                varName = String(decoding: buf, as: UTF8.self)

            case 2: // MSSP_VAL
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] != 1 && src[j] != 2 && src[j] != TC.IAC {
                    buf.append(src[j])
                    j += 1
                }
                if !varName.isEmpty {
                    data[varName] = String(decoding: buf, as: UTF8.self)
                }

            default:
                j += 1
            }
        }

        if !data.isEmpty {
            delegate?.onMSSPReceived(data: data)
        }

        return sbLen
    }

    // MARK: - Handler: Echo

    private func processWillEcho() {
        serverOptions.insert(TO.ECHO)
        serverEcho = true
        write([TC.IAC, TC.DO, TO.ECHO])
        delegate?.onLocalEchoChanged(enabled: false)
    }

    private func processWontEcho() {
        serverOptions.remove(TO.ECHO)
        serverEcho = false
        write([TC.IAC, TC.DONT, TO.ECHO])
        delegate?.onLocalEchoChanged(enabled: true)
    }

    // MARK: - Handler: EOR

    private func processWillEor() {
        serverOptions.insert(TO.EOR)
        write([TC.IAC, TC.DO, TO.EOR])
    }

    // MARK: - Handler: SGA

    private func processWillSga() {
        serverOptions.insert(TO.SGA)
        write([TC.IAC, TC.DO, TO.SGA])
    }

    // MARK: - Handler: TTYPE

    private func processDoTtype() {
        clientOptions.insert(TO.TTYPE)
        ttypeRound = 0
        write([TC.IAC, TC.WILL, TO.TTYPE])
    }

    private func processSbTtypeSend() {
        let name: String
        switch ttypeRound {
        case 0:
            name = terminalType
        case 1:
            name = "\(terminalType)-256color"
        default:
            name = "MTTS \(mttsFlags)"
        }
        ttypeRound += 1

        var packet: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS]
        packet.append(contentsOf: name.utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    // MARK: - Handler: NAWS

    private func processDoNaws() {
        clientOptions.insert(TO.NAWS)
        write([TC.IAC, TC.WILL, TO.NAWS])
        sendNawsPacket()
    }

    private func sendNawsPacket() {
        let colsHi = UInt8((windowWidth >> 8) & 0xFF)
        let colsLo = UInt8(windowWidth & 0xFF)
        let rowsHi = UInt8((windowHeight >> 8) & 0xFF)
        let rowsLo = UInt8(windowHeight & 0xFF)

        var packet: [UInt8] = [TC.IAC, TC.SB, TO.NAWS]
        addNawsByte(&packet, colsHi)
        addNawsByte(&packet, colsLo)
        addNawsByte(&packet, rowsHi)
        addNawsByte(&packet, rowsLo)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    private func addNawsByte(_ packet: inout [UInt8], _ b: UInt8) {
        packet.append(b)
        if b == TC.IAC { packet.append(b) }
    }
}
