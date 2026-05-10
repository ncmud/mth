import Foundation

/// One inbound GMCP packet, ready for the host to consume.
///
/// Consumers identify the packet by `module` and pull the body out as a typed
/// value via `decode(_:)`. Module-only packets like `Core.Ping` carry no body
/// and `decode` returns `nil` for them; malformed JSON throws.
public struct GMCPPacket: Sendable {
    /// GMCP module name (e.g. `"Char.Login.Credentials"`). Always non-empty:
    /// packets with an empty SB body never produce a `GMCPPacket`.
    public let module: String

    /// JSON payload bytes following the module name. Internal — consumers
    /// should go through `decode(_:)` rather than reach for the raw bytes.
    let payload: Data

    /// Size of the JSON payload in bytes. Useful for size-cap policies
    /// (e.g. drop packets larger than N KB) without exposing the bytes.
    public var byteCount: Int { payload.count }

    init(module: String, payload: Data) {
        self.module = module
        self.payload = payload
    }

    /// Decode the payload as JSON into the requested `Decodable` type.
    ///
    /// Returns `nil` for module-only packets that carry no body. Throws
    /// `DecodingError` from `JSONDecoder` on malformed JSON or shape mismatch.
    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T? {
        guard !payload.isEmpty else { return nil }
        return try decoder.decode(type, from: payload)
    }
}

/// Delegate for `TelnetSession` to communicate with the host application.
///
/// Replaces the C `descriptor_data` extensibility pattern. The session calls
/// these methods for I/O and data that the host must provide.
public protocol TelnetSessionDelegate: AnyObject {
    /// Write raw bytes to the client connection.
    /// The session calls this for all outbound data (telnet negotiations,
    /// MSDP updates, echo control, etc.).
    func telnetSession(_ session: TelnetSession, write data: [UInt8])

    /// Log a diagnostic message.
    func telnetSession(_ session: TelnetSession, log message: String)

    /// Return MSSP (Mud Server Status Protocol) key-value pairs.
    /// Called when the client requests MSSP data.
    func telnetSessionMSSPData(_ session: TelnetSession) -> [(key: String, value: String)]

    /// Inbound GMCP packet, surfaced as a `GMCPPacket` with the raw module
    /// name plus its (possibly empty) JSON payload — the form most consumers
    /// actually want for nested-object packages like `Char.Login.Credentials`.
    ///
    /// Fires for every well-formed inbound `IAC SB GMCP … IAC SE` block (those
    /// with a non-empty body — empty SB GMCP blocks have no module name and
    /// are skipped). Fires regardless of whether the host also has an
    /// `MSDPManager` attached. The MSDP-flat-var fallback at `processSbGmcp`
    /// still runs after the delegate returns, so existing flat-var consumers
    /// (`Core.Hello`, etc.) keep working unchanged.
    ///
    /// To consume a packet as a typed value, use the packet's `decode(_:)`:
    /// ```
    /// guard packet.module == "Char.Login.Credentials",
    ///       let creds = try packet.decode(Credentials.self)
    /// else { return }
    /// // use creds
    /// ```
    func telnetSession(_ session: TelnetSession, gmcpReceived packet: GMCPPacket)
}

/// Default implementations for optional delegate methods.
public extension TelnetSessionDelegate {
    func telnetSession(_ session: TelnetSession, log message: String) {}
    func telnetSessionMSSPData(_ session: TelnetSession) -> [(key: String, value: String)] { [] }
    func telnetSession(_ session: TelnetSession, gmcpReceived packet: GMCPPacket) {}
}
