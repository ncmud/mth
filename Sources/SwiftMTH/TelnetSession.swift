import Foundation

private typealias TC = TelnetCommand
private typealias TO = TelnetOption
private typealias TS = TelnetSub

/// A single telnet session, managing protocol negotiation state.
///
/// Replaces the C `mth_data` struct and the `translate_telopts` function.
/// Each instance corresponds to one client connection.
public final class TelnetSession {

    // MARK: - Public State

    public weak var delegate: TelnetSessionDelegate?
    public private(set) var terminalType: String = ""
    public private(set) var mttsFlags: MTTSFlags = []
    public private(set) var windowSize: (cols: Int, rows: Int) = (0, 0)
    public private(set) var commFlags: CommFlags = []
    public private(set) var proxy: String = ""

    /// The MSDP manager for this session. Created lazily when MSDP/GMCP is negotiated.
    public private(set) var msdpManager: MSDPManager?

    /// The telnet option announcement table.
    public let telnetTable: [TelnetOptionEntry]

    /// The MSDP variable definitions to use when MSDP is initialized.
    public let msdpTable: [MSDPVariableDefinition]

    #if canImport(CZlib)
    /// Whether MCCP2 compression is active for outbound data.
    public var isMCCP2Active: Bool { mccp2 != nil }

    /// Whether MCCP3 decompression is active for inbound data.
    public var isMCCP3Active: Bool { mccp3 != nil }
    #else
    /// Whether MCCP2 compression is active for outbound data (unavailable without zlib).
    public var isMCCP2Active: Bool { false }

    /// Whether MCCP3 decompression is active for inbound data (unavailable without zlib).
    public var isMCCP3Active: Bool { false }
    #endif

    // MARK: - Private State

    /// Buffer for incomplete telnet sequences (packet fragmentation).
    private var telbuf: [UInt8] = []

    #if canImport(CZlib)
    /// MCCP2 deflate stream (server→client output compression).
    private var mccp2: DeflateStream?

    /// MCCP3 inflate stream (client→server input decompression).
    private var mccp3: InflateStream?
    #endif

    // MARK: - Init

    public init(
        delegate: TelnetSessionDelegate? = nil,
        telnetTable: [TelnetOptionEntry] = defaultTelnetTable,
        msdpTable: [MSDPVariableDefinition] = defaultMSDPTable
    ) {
        self.delegate = delegate
        self.telnetTable = telnetTable
        self.msdpTable = msdpTable
    }

    /// Restore a TelnetSession from saved copyover state.
    /// Sets negotiated flags directly without sending announcements to the client.
    public init(
        restoring commFlags: CommFlags,
        mttsFlags: MTTSFlags,
        terminalType: String,
        windowSize: (cols: Int, rows: Int),
        proxy: String,
        delegate: TelnetSessionDelegate? = nil,
        telnetTable: [TelnetOptionEntry] = defaultTelnetTable,
        msdpTable: [MSDPVariableDefinition] = defaultMSDPTable
    ) {
        self.delegate = delegate
        self.telnetTable = telnetTable
        self.msdpTable = msdpTable
        self.commFlags = commFlags
        self.mttsFlags = mttsFlags
        self.terminalType = terminalType
        self.windowSize = windowSize
        self.proxy = proxy
    }

    // MARK: - Connection Lifecycle

    /// Announce support for negotiated telnet options.
    /// Call once after connection is established.
    public func announceSupport() {
        for i in 0..<min(telnetTable.count, 255) {
            let entry = telnetTable[i]
            if !entry.announce.isEmpty {
                if entry.announce.contains(.will) {
                    write([TC.IAC, TC.WILL, UInt8(i)])
                }
                if entry.announce.contains(.do) {
                    write([TC.IAC, TC.DO, UInt8(i)])
                }
            }
        }
    }

    /// Unannounce support (e.g. before copyover).
    public func unannounceSupport() {
        #if canImport(CZlib)
        endMCCP2()
        endMCCP3()
        #endif
        for i in 0..<min(telnetTable.count, 255) {
            let entry = telnetTable[i]
            if !entry.announce.isEmpty {
                if entry.announce.contains(.will) {
                    write([TC.IAC, TC.WONT, UInt8(i)])
                }
                if entry.announce.contains(.do) {
                    write([TC.IAC, TC.DONT, UInt8(i)])
                }
            }
        }
    }

    /// Re-send `IAC WILL` for every table option that is not already in effect.
    /// For a session whose negotiated state was reconstructed rather than
    /// negotiated, this is the only way an option the client never agreed to
    /// gets offered again — no client volunteers `DO` unprompted.
    ///
    /// The `.do` half of the table is deliberately left alone: re-offering
    /// TTYPE/NAWS/NEW_ENVIRON restarts subnegotiation for data already held.
    public func reannounceWillOptions() {
        for i in 0..<min(telnetTable.count, 255)
        where telnetTable[i].announce.contains(.will) && !isOptionActive(UInt8(i)) {
            write([TC.IAC, TC.WILL, UInt8(i)])
        }
    }

    /// An option whose state this session does not track answers `false`, so a
    /// caller re-offers it rather than assuming it survived.
    private func isOptionActive(_ option: UInt8) -> Bool {
        switch option {
        case TO.EOR: commFlags.contains(.eor)
        case TO.MSDP: msdpManager != nil
        case TO.MCCP2: isMCCP2Active
        case TO.MXP: commFlags.contains(.mxp)
        case TO.GMCP: commFlags.contains(.gmcp)
        default: false
        }
    }

    /// Re-send IAC WILL GMCP to the client. Uses the internal write path
    /// so MCCP2 compression is handled correctly.
    public func reannounceGMCP() {
        write([TC.IAC, TC.WILL, TO.GMCP])
    }

    /// Whether the client negotiated MXP (telnet option 91).
    public var mxpEnabled: Bool { commFlags.contains(.mxp) }

    /// Re-assert the locked-default MXP line mode after a copyover restore, for a
    /// client that had MXP enabled. See `processDoMxp`.
    public func reassertMXP() {
        guard commFlags.contains(.mxp) else { return }
        write(TelnetSession.mxpLockedDefault)
    }

    /// Send echo-off (password mode).
    public func sendEchoOff() {
        commFlags.insert(.password)
        write([TC.IAC, TC.WILL, TO.ECHO])
    }

    /// Send echo-on (normal mode).
    public func sendEchoOn() {
        commFlags.remove(.password)
        write([TC.IAC, TC.WONT, TO.ECHO])
    }

    /// Send End-of-Record marker (prompt marker).
    public func sendEOR() {
        if commFlags.contains(.eor) {
            write([TC.IAC, TC.EOR])
        }
    }

    /// Send MSDP update if needed. Call periodically (e.g. each tick).
    public func flushMSDPUpdates() {
        msdpManager?.flushUpdates()
    }

    /// Send a GMCP packet with the given module name and JSON payload.
    /// Only sends if the client negotiated GMCP.
    public func sendGMCP(_ module: String, json: String) {
        guard commFlags.contains(.gmcp) else { return }
        var packet: [UInt8] = [TC.IAC, TC.SB, TO.GMCP]
        packet.append(contentsOf: module.utf8)
        packet.append(UInt8(ascii: " "))
        packet.append(contentsOf: json.utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    /// Send an MSP trigger as a telnet subnegotiation (IAC SB MSP ... IAC SE).
    /// The payload should be a complete MSP trigger, e.g. "!!SOUND(file.wav V=50)".
    public func sendMSP(_ payload: String) {
        var packet: [UInt8] = [TC.IAC, TC.SB, TO.MSP]
        packet.append(contentsOf: payload.utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    // MARK: - Input Processing

    /// Process raw input from the client. Strips telnet negotiations,
    /// handles \r\0 → \n conversion, and returns clean text.
    ///
    /// Equivalent to C `translate_telopts`.
    public func processInput(_ src: [UInt8]) -> [UInt8] {
        var input = src

        #if canImport(CZlib)
        // MCCP3: decompress incoming data if active
        if let inflater = mccp3 {
            guard let result = inflater.decompress(input) else {
                log("MCCP3: Compression error, disabling MCCP3.")
                write([TC.IAC, TC.DONT, TO.MCCP3])
                endMCCP3()
                return []
            }
            if result.finished {
                log("MCCP3: Compression end, disabling MCCP3.")
                endMCCP3()
                // Decompressed data + any trailing uncompressed data
                input = result.decompressed + result.unconsumedInput
            } else {
                input = result.decompressed
            }
        }
        #endif

        var out: [UInt8] = []
        out.reserveCapacity(input.count)

        // Reassemble fragmented packets
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

                // Try to match against the telopt dispatch table
                let (skip, matched) = dispatchTelopt(input, at: i, remaining: remaining)

                if !matched && remaining > 1 {
                    // No handler matched — handle generic telnet commands
                    let genericSkip = handleGenericTelnet(input, at: i, remaining: remaining, out: &out)
                    if genericSkip <= remaining {
                        i += genericSkip
                    } else {
                        // Incomplete — buffer for next call
                        telbuf = Array(input[i...])
                        return out
                    }
                } else if skip <= remaining {
                    i += skip
                } else {
                    // Incomplete telnet sequence — buffer for next call
                    telbuf = Array(input[i...])
                    return out
                }

            case 0x0D: // \r
                if i + 1 < input.count && input[i + 1] == 0x00 {
                    out.append(0x0A) // \r\0 → \n
                }
                // \r alone or \r\n — skip \r, let \n be handled next iteration
                i += 1

            case 0x00: // \0
                i += 1

            default:
                out.append(input[i])
                i += 1
            }
        }

        return out
    }

    // MARK: - Telopt Dispatch

    /// Pattern entries for matching telnet sequences to handlers.
    private struct TeloptPattern {
        let pattern: [UInt8]
        let handler: (TelnetSession, [UInt8], Int, Int) -> Int
    }

    /// Try to match input at position against known telopt patterns.
    /// Returns (skip count, matched).
    private func dispatchTelopt(_ src: [UInt8], at i: Int, remaining: Int) -> (Int, Bool) {
        for entry in teloptPatterns {
            if remaining < entry.pattern.count {
                // Check if it's a partial match (incomplete packet)
                let available = Array(src[i..<i + remaining])
                if available.elementsEqual(entry.pattern.prefix(remaining)) {
                    return (entry.pattern.count, true) // signal incomplete
                }
            } else {
                let slice = src[i..<i + entry.pattern.count]
                if slice.elementsEqual(entry.pattern) {
                    let skip = entry.handler(self, src, i, remaining)
                    return (skip, true)
                }
            }
        }
        return (2, false) // no match
    }

    /// Lazily built telopt pattern table.
    private lazy var teloptPatterns: [TeloptPattern] = buildTeloptPatterns()

    private func buildTeloptPatterns() -> [TeloptPattern] {
        var patterns: [TeloptPattern] = [
            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.EOR],
                          handler: { s, src, i, n in s.processDoEOR(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.DONT, TO.EOR],
                          handler: { s, src, i, n in s.processDontEOR(); return 3 }),

            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.TTYPE],
                          handler: { s, src, i, n in s.processWillTtype(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_IS],
                          handler: { s, src, i, n in s.processSbTtypeIs(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.NAWS],
                          handler: { s, src, i, n in s.processSbNaws(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.WILL, TO.NEW_ENVIRON],
                          handler: { s, src, i, n in s.processWillNewEnviron(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.NEW_ENVIRON],
                          handler: { s, src, i, n in s.processSbNewEnviron(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.CHARSET],
                          handler: { s, src, i, n in s.processDoCharset(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.CHARSET],
                          handler: { s, src, i, n in s.processSbCharset(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.MSSP],
                          handler: { s, src, i, n in s.processDoMssp(); return 3 }),

            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.MSDP],
                          handler: { s, src, i, n in s.processDoMsdp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MSDP],
                          handler: { s, src, i, n in s.processSbMsdp(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.GMCP],
                          handler: { s, src, i, n in s.processDoGmcp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.GMCP],
                          handler: { s, src, i, n in s.processSbGmcp(src, at: i, srclen: n) }),

            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.MXP],
                          handler: { s, src, i, n in s.processDoMxp(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.DONT, TO.MXP],
                          handler: { s, src, i, n in s.processDontMxp(); return 3 }),
        ]
        #if canImport(CZlib)
        patterns += [
            // MCCP2
            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.MCCP2],
                          handler: { s, src, i, n in s.processDoMccp2(); return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.DONT, TO.MCCP2],
                          handler: { s, src, i, n in s.processDontMccp2(); return 3 }),

            // MCCP3
            TeloptPattern(pattern: [TC.IAC, TC.DO, TO.MCCP3],
                          handler: { s, src, i, n in return 3 }),
            TeloptPattern(pattern: [TC.IAC, TC.SB, TO.MCCP3, TC.IAC, TC.SE],
                          handler: { s, src, i, n in s.processSbMccp3(); return 5 }),
        ]
        #endif
        return patterns
    }

    /// Handle generic telnet commands that don't match any specific pattern.
    private func handleGenericTelnet(_ src: [UInt8], at i: Int, remaining: Int, out: inout [UInt8]) -> Int {
        guard remaining > 1 else { return remaining + 1 } // incomplete

        switch src[i + 1] {
        case TC.WILL, TC.DO, TC.WONT, TC.DONT:
            return 3

        case TC.SB:
            return skipSB(src, at: i, srclen: remaining)

        case TC.IAC:
            // IAC IAC → literal 0xFF
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

    /// Find the end of a subnegotiation (IAC SE). Returns skip count.
    /// Returns remaining+1 if incomplete.
    private func skipSB(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let end = offset + srclen
        var j = offset + 1
        while j < end {
            if src[j] == TC.SE && j > offset && src[j - 1] == TC.IAC {
                return j - offset + 1
            }
            j += 1
        }
        return srclen + 1 // incomplete
    }

    // MARK: - Output

    /// Send output data to the client, compressing via MCCP2 if active.
    /// Host applications must route all socket output through this method
    /// once MCCP2 negotiation completes, otherwise clients receive
    /// uncompressed data after the MCCP2 start marker.
    public func sendOutput(_ data: [UInt8]) {
        write(data)
    }

    private func write(_ data: [UInt8]) {
        #if canImport(CZlib)
        if let mccp2 = mccp2 {
            if let compressed = mccp2.compress(data) {
                delegate?.telnetSession(self, write: compressed)
            }
        } else {
            delegate?.telnetSession(self, write: data)
        }
        #else
        delegate?.telnetSession(self, write: data)
        #endif
    }

    /// Write data bypassing MCCP2 compression (used for the MCCP2 start marker).
    private func writeRaw(_ data: [UInt8]) {
        delegate?.telnetSession(self, write: data)
    }

    private func log(_ message: String) {
        delegate?.telnetSession(self, log: message)
    }

    // MARK: - Handler: EOR

    private func processDoEOR() {
        commFlags.insert(.eor)
    }

    private func processDontEOR() {
        commFlags.remove(.eor)
    }

    // MARK: - Handler: Terminal Type

    private func processWillTtype() {
        if terminalType.isEmpty {
            // Request terminal type 3 times for MTTS detection, then reset
            let request: [UInt8] = [TC.IAC, TC.SB, TO.TTYPE, TS.ENV_SEND, TC.IAC, TC.SE]
            write(request)
            write(request)
            write(request)
            write([TC.IAC, TC.DONT, TO.TTYPE])
        }
    }

    private func processSbTtypeIs(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        // Extract terminal type value from: IAC SB TTYPE IS <value> IAC SE
        var val: [UInt8] = []
        var j = offset + 4
        let end = offset + srclen
        while j < end {
            if src[j] == TC.IAC { break }
            val.append(src[j])
            j += 1
        }
        let value = String(decoding: val, as: UTF8.self)

        if terminalType.isEmpty {
            terminalType = value
        } else {
            // Check for MTTS flags
            if value.uppercased().hasPrefix("MTTS ") {
                if let flags = Int(value.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                    mttsFlags = MTTSFlags(rawValue: flags)

                    if mttsFlags.contains(.colors256) {
                        commFlags.insert(.colors256)
                    }
                    if mttsFlags.contains(.utf8) {
                        commFlags.insert(.utf8)
                    }
                }
            }

            // Detect 256-color terminals by name
            let upper = value.uppercased()
            if upper.contains("-256COLOR") || upper == "XTERM" {
                commFlags.insert(.colors256)
            }
        }

        return sbLen
    }

    // MARK: - Handler: NAWS

    private func processSbNaws(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        // NAWS data starts at offset+3: 2 bytes cols (big-endian), 2 bytes rows
        // IAC bytes are doubled (stuffed) in NAWS values
        var cols = 0
        var rows = 0
        var j = offset + 3
        let end = offset + srclen

        // Parse 4 value bytes with IAC stuffing
        for field in 0..<4 {
            guard j < end else { break }
            let byte = Int(src[j])
            if src[j] == TC.IAC && j + 1 < end {
                j += 1 // skip stuffed IAC
            }
            j += 1

            switch field {
            case 0: cols += byte * 256
            case 1: cols += byte
            case 2: rows += byte * 256
            case 3: rows += byte
            default: break
            }
        }

        windowSize = (cols: cols, rows: rows)
        return sbLen
    }

    // MARK: - Handler: NEW-ENVIRON

    private func processWillNewEnviron() {
        var packet: [UInt8] = [TC.IAC, TC.SB, TO.NEW_ENVIRON, TS.ENV_SEND, TS.ENV_VAR]
        packet.append(contentsOf: "SYSTEMTYPE".utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    private func processSbNewEnviron(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        var varName = ""
        var j = offset + 4
        let end = offset + srclen
        let subCommand = src[offset + 3] // ENV_IS, ENV_SEND, or ENV_INFO

        while j < end && src[j] != TC.SE {
            switch src[j] {
            case TS.ENV_VAR, TS.ENV_USR:
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] >= 32 && src[j] != TC.IAC {
                    buf.append(src[j])
                    j += 1
                }
                varName = String(decoding: buf, as: UTF8.self)

            case TS.ENV_VAL:
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] >= 32 && src[j] != TC.IAC {
                    buf.append(src[j])
                    j += 1
                }
                let valName = String(decoding: buf, as: UTF8.self)

                if subCommand == TS.ENV_IS {
                    if varName.caseInsensitiveCompare("SYSTEMTYPE") == .orderedSame
                        && valName.caseInsensitiveCompare("WIN32") == .orderedSame {
                        if terminalType.caseInsensitiveCompare("ANSI") == .orderedSame {
                            commFlags.insert(.remoteEcho)
                            terminalType = "WINDOWS TELNET"
                        }
                    }
                    if varName.caseInsensitiveCompare("IPADDRESS") == .orderedSame {
                        proxy = valName
                    }
                }

            default:
                j += 1
            }
        }

        return sbLen
    }

    // MARK: - Handler: CHARSET

    private func processDoCharset() {
        var packet: [UInt8] = [TC.IAC, TC.SB, TO.CHARSET, TS.CHARSET_REQUEST, UInt8(ascii: " ")]
        packet.append(contentsOf: "UTF-8".utf8)
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    private func processSbCharset(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        let subCommand = src[offset + 3]
        let separator = src[offset + 4]
        var j = offset + 5
        let end = offset + srclen

        while j < end && src[j] != TC.SE && src[j] != separator {
            var buf: [UInt8] = []
            while j < end && src[j] != separator && src[j] != TC.IAC {
                buf.append(src[j])
                j += 1
            }
            let charset = String(decoding: buf, as: UTF8.self)

            if subCommand == TS.CHARSET_ACCEPTED {
                if charset.caseInsensitiveCompare("UTF-8") == .orderedSame {
                    commFlags.insert(.utf8)
                }
            } else if subCommand == TS.CHARSET_REJECTED {
                if charset.caseInsensitiveCompare("UTF-8") == .orderedSame {
                    commFlags.remove(.utf8)
                }
            }
            j += 1
        }

        return sbLen
    }

    // MARK: - Handler: MSSP

    private func processDoMssp() {
        guard let delegate = delegate else { return }
        let pairs = delegate.telnetSessionMSSPData(self)

        var packet: [UInt8] = [TC.IAC, TC.SB, TO.MSSP]
        for pair in pairs {
            packet.append(TS.MSSP_VAR)
            packet.append(contentsOf: pair.key.utf8)
            packet.append(TS.MSSP_VAL)
            packet.append(contentsOf: pair.value.utf8)
        }
        packet.append(TC.IAC)
        packet.append(TC.SE)
        write(packet)
    }

    // MARK: - Handler: MSDP

    private func processDoMsdp() {
        if msdpManager != nil { return }
        initializeMSDP()
        log("INFO MSDP INITIALIZED")
    }

    /// Initialize MSDP manager for copyover restore (no negotiation announcements).
    public func initializeMSDPForRestore(usesGMCP: Bool) {
        guard msdpManager == nil else { return }
        initializeMSDP()
        msdpManager?.usesGMCP = usesGMCP
    }

    private func initializeMSDP() {
        msdpManager = MSDPManager(
            table: msdpTable,
            writeHandler: { [weak self] data in
                guard let self = self else { return }
                self.write(data)
            },
            logHandler: { [weak self] message in
                guard let self = self else { return }
                self.log(message)
            }
        )
        msdpManager?.usesGMCP = commFlags.contains(.gmcp)
        msdpManager?.updateVariable("SPECIFICATION", value: "http://tintin.sourceforge.net/msdp")
    }

    private func processSbMsdp(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        guard let mgr = msdpManager else { return sbLen }

        var varName = ""
        var j = offset + 3
        let end = offset + srclen

        while j < end && src[j] != TC.SE {
            switch src[j] {
            case 1: // MSDP_VAR
                j += 1
                var buf: [UInt8] = []
                while j < end && src[j] != 2 && src[j] != TC.IAC { // not MSDP_VAL or IAC
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
                    } else if nest == 0 && (src[j] == 1 || src[j] == 2) { // VAR or VAL
                        break
                    }
                    buf.append(src[j])
                    j += 1
                }
                let valStr = String(decoding: buf, as: UTF8.self)
                if nest == 0 {
                    mgr.processVarVal(varName, value: valStr)
                }

            default:
                j += 1
            }
        }

        return sbLen
    }

    // MARK: - Handler: MXP

    /// `ESC[7z` — Lock Locked: makes "locked" the persistent default line mode across
    /// newlines, so normal output (with stray `< > &`) is never parsed as MXP markup.
    /// Links opt back in per-span with `ESC[1z … ESC[2z`. (Zugg MXP line-mode spec.)
    private static let mxpLockedDefault: [UInt8] = [0x1B, 0x5B, 0x37, 0x7A]

    private func processDoMxp() {
        guard !commFlags.contains(.mxp) else { return }
        commFlags.insert(.mxp)
        write(TelnetSession.mxpLockedDefault)
        log("INFO MXP ENABLED")
    }

    private func processDontMxp() {
        commFlags.remove(.mxp)
    }

    // MARK: - Handler: GMCP

    private func processDoGmcp() {
        commFlags.insert(.gmcp)
        if msdpManager != nil {
            msdpManager?.usesGMCP = true
            log("INFO GMCP ENABLED (MSDP already active)")
            return
        }
        log("INFO MSDP OVER GMCP INITIALIZED")
        initializeMSDP()
    }

    private func processSbGmcp(_ src: [UInt8], at offset: Int, srclen: Int) -> Int {
        let sbLen = skipSB(src, at: offset, srclen: srclen)
        if sbLen > srclen { return srclen + 1 }

        // Surface raw module + JSON payload to the delegate before the MSDP
        // fallback runs. SB framing: [IAC, SB, GMCP, <body>, IAC, SE].
        if let delegate = delegate, sbLen >= 5 {
            let bodyStart = offset + 3
            let bodyEnd = offset + sbLen - 2
            if bodyEnd > bodyStart {
                var splitIdx = bodyStart
                while splitIdx < bodyEnd && src[splitIdx] != UInt8(ascii: " ") {
                    splitIdx += 1
                }
                let module = String(decoding: src[bodyStart..<splitIdx], as: UTF8.self)
                if !module.isEmpty {
                    let jsonStart = splitIdx < bodyEnd ? splitIdx + 1 : bodyEnd
                    let payload = Data(src[jsonStart..<bodyEnd])
                    delegate.telnetSession(
                        self, gmcpReceived: GMCPPacket(module: module, payload: payload))
                }
            }
        }

        // Convert JSON to MSDP and process
        let gmcpPacket = Array(src[offset..<offset + srclen])
        let msdpPacket = json2msdp(gmcpPacket)

        // Process the converted MSDP packet
        if let mgr = msdpManager {
            // Parse the converted packet directly
            var varName = ""
            var j = 3 // skip IAC SB MSDP
            while j < msdpPacket.count {
                if msdpPacket[j] == TC.IAC { break }
                switch msdpPacket[j] {
                case 1: // MSDP_VAR
                    j += 1
                    var buf: [UInt8] = []
                    while j < msdpPacket.count && msdpPacket[j] != 2 && msdpPacket[j] != TC.IAC {
                        buf.append(msdpPacket[j])
                        j += 1
                    }
                    varName = String(decoding: buf, as: UTF8.self)
                case 2: // MSDP_VAL
                    j += 1
                    var buf: [UInt8] = []
                    var nest = 0
                    while j < msdpPacket.count && msdpPacket[j] != TC.IAC {
                        if msdpPacket[j] == 3 || msdpPacket[j] == 5 { nest += 1 }
                        else if msdpPacket[j] == 4 || msdpPacket[j] == 6 { nest -= 1 }
                        else if nest == 0 && (msdpPacket[j] == 1 || msdpPacket[j] == 2) { break }
                        buf.append(msdpPacket[j])
                        j += 1
                    }
                    if nest == 0 {
                        mgr.processVarVal(varName, value: String(decoding: buf, as: UTF8.self))
                    }
                default:
                    j += 1
                }
            }
        }

        return sbLen
    }

    #if canImport(CZlib)
    // MARK: - Handler: MCCP2

    private func processDoMccp2() {
        startMCCP2()
    }

    private func processDontMccp2() {
        endMCCP2()
    }

    /// Start MCCP2 compression. Sends the start marker uncompressed,
    /// then all subsequent write() calls are compressed.
    private func startMCCP2() {
        guard mccp2 == nil else { return }
        guard let stream = DeflateStream() else {
            log("MCCP2: failed to initialize deflate stream")
            return
        }

        // Send the MCCP2 start marker BEFORE enabling compression
        writeRaw([TC.IAC, TC.SB, TO.MCCP2, TC.IAC, TC.SE])

        mccp2 = stream
    }

    /// End MCCP2 compression.
    public func endMCCP2() {
        guard let stream = mccp2 else { return }

        // Flush remaining compressed data
        if !commFlags.contains(.disconnect) {
            if let final = stream.finish() {
                delegate?.telnetSession(self, write: final)
            }
        }

        mccp2 = nil
        log("MCCP2: COMPRESSION END")
    }

    // MARK: - Handler: MCCP3

    private func processSbMccp3() {
        endMCCP3()

        guard let stream = InflateStream() else {
            log("INFO IAC SB MCCP3 FAILED TO INITIALIZE")
            write([TC.IAC, TC.WONT, TO.MCCP3])
            return
        }

        mccp3 = stream
        log("INFO IAC SB MCCP3 INITIALIZED")
    }

    /// End MCCP3 decompression.
    public func endMCCP3() {
        guard mccp3 != nil else { return }
        log("MCCP3: COMPRESSION END")
        mccp3 = nil
    }
    #else
    /// No-op: MCCP2 unavailable without zlib.
    public func endMCCP2() {}

    /// No-op: MCCP3 unavailable without zlib.
    public func endMCCP3() {}
    #endif
}
