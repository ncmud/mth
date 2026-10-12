import Foundation

/// Client-reported settings. An IP address is a claim, not an authenticated peer address.
public struct MNESEnvironment: Codable, Equatable, Sendable {
    public var clientName: String?
    public var clientVersion: String?
    public var charset: String?
    public var ipAddress: String?
    public var mtts: Int?
    public var terminalType: String?

    public init(clientName: String? = nil, clientVersion: String? = nil,
                charset: String? = nil, ipAddress: String? = nil,
                mtts: Int? = nil, terminalType: String? = nil) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.charset = charset
        self.ipAddress = ipAddress
        self.mtts = mtts
        self.terminalType = terminalType
    }

    public static let variableNames = ["IPADDRESS", "CLIENT_NAME", "CLIENT_VERSION", "CHARSET", "MTTS", "TERMINAL_TYPE"]

    public var variables: [String: String] {
        var result: [String: String] = [:]
        result["CLIENT_NAME"] = clientName
        result["CLIENT_VERSION"] = clientVersion
        result["CHARSET"] = charset
        result["IPADDRESS"] = ipAddress
        result["MTTS"] = mtts.map(String.init)
        result["TERMINAL_TYPE"] = terminalType
        return result
    }

    /// Applies valid settings; undefined values remove an earlier report.
    public mutating func apply(_ entries: [NewEnviron.Entry]) {
        for entry in entries {
            if let value = entry.value,
               (value.utf8.count > 256 || value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) {
                continue
            }
            let value = entry.value.flatMap { $0.isEmpty ? nil : $0 }
            switch entry.name {
            case "CLIENT_NAME": clientName = value
            case "CLIENT_VERSION": clientVersion = value
            case "CHARSET": charset = value?.uppercased()
            case "TERMINAL_TYPE": terminalType = value
            case "IPADDRESS":
                if value == nil || Self.isIPAddress(value!) { ipAddress = value }
            case "MTTS":
                if let value {
                    if value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                       let number = Int(value), number <= Int(Int32.max) { mtts = number }
                } else { mtts = nil }
            default: break
            }
        }
    }

    public var validated: Self {
        var result = Self()
        result.apply(variables.map { NewEnviron.Entry(name: $0.key, value: $0.value) })
        return result
    }

    public static func isIPAddress(_ value: String) -> Bool {
        func ipv4(_ value: String) -> Bool {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy {
                !$0.isEmpty && $0.count <= 3 && ($0.count == 1 || $0.first != "0") &&
                $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && Int($0)! <= 255
            }
        }
        if !value.contains(":") { return ipv4(value) }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        var groups = 0
        let parts = value.split(separator: ":", omittingEmptySubsequences: true)
        for (index, part) in parts.enumerated() {
            if part.contains(".") {
                guard index == parts.count - 1, value.hasSuffix(String(part)), ipv4(String(part)) else { return false }
                groups += 2
            } else {
                guard part.count <= 4, part.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
                groups += 1
            }
        }
        if halves.count == 2 {
            return groups < 8 && halves.allSatisfy { !$0.hasPrefix(":") && !$0.hasSuffix(":") }
        }
        return groups == 8 && !value.hasPrefix(":") && !value.hasSuffix(":")
    }
}

/// NEW-ENVIRON framing and RFC 1572 escaping, shared by clients and servers.
public enum NewEnviron {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let value: String?
        public let userDefined: Bool
        public init(name: String, value: String? = nil, userDefined: Bool = false) {
            self.name = name
            self.value = value
            self.userDefined = userDefined
        }
    }

    /// Returns the complete frame length, or nil while awaiting its terminator.
    public static func frameLength(_ bytes: [UInt8], at offset: Int) -> Int? {
        var i = offset + 3
        while i + 1 < bytes.count {
            if bytes[i] == 255 {
                if bytes[i + 1] == 240 { return i + 2 - offset }
                i += 2
            } else { i += 1 }
        }
        return nil
    }

    public static func decode(_ frame: [UInt8]) -> (command: UInt8, entries: [Entry])? {
        guard frame.count >= 6, frame.count <= 8192,
              frame.prefix(3) == [255, 250, 39], frame.suffix(2) == [255, 240], frame[3] <= 2 else { return nil }
        var payload: [UInt8] = []
        var i = 4
        while i < frame.count - 2 {
            let byte = frame[i]
            if byte == 255 {
                guard i + 1 < frame.count - 2, frame[i + 1] == 255 else { return nil }
                i += 1
            }
            payload.append(byte)
            i += 1
        }
        var entries: [Entry] = []
        var name: [UInt8]? = nil
        var value: [UInt8]? = nil
        var userDefined = false
        func finish() -> Bool {
            guard let name else { return true }
            guard name.count <= 64, let key = String(bytes: name, encoding: .utf8),
                  value == nil || String(bytes: value!, encoding: .utf8) != nil else { return false }
            entries.append(Entry(name: key, value: value.map { String(decoding: $0, as: UTF8.self) }, userDefined: userDefined))
            return entries.count <= 64
        }
        i = 0
        while i < payload.count {
            let byte = payload[i]
            switch byte {
            case 0, 3:
                guard finish() else { return nil }
                name = []; value = nil; userDefined = byte == 3
            case 1:
                guard name != nil, value == nil else { return nil }
                value = []
            case 2:
                i += 1
                guard i < payload.count, name != nil else { return nil }
                if value != nil { value!.append(payload[i]) } else { name!.append(payload[i]) }
            default:
                guard name != nil else { return nil }
                if value != nil { value!.append(byte) } else { name!.append(byte) }
            }
            i += 1
        }
        guard finish() else { return nil }
        return (frame[3], entries)
    }

    public static func packet(command: UInt8, entries: [Entry]) -> [UInt8] {
        var result: [UInt8] = [255, 250, 39, command]
        func append(_ text: String) {
            for byte in text.utf8 {
                if byte <= 3 { result.append(2) }
                if byte == 255 { result.append(255) }
                result.append(byte)
            }
        }
        for entry in entries {
            result.append(entry.userDefined ? 3 : 0); append(entry.name)
            if let value = entry.value { result.append(1); append(value) }
        }
        return result + [255, 240]
    }
}
