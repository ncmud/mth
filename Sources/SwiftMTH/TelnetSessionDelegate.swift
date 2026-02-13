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
}

/// Default implementations for optional delegate methods.
public extension TelnetSessionDelegate {
    func telnetSession(_ session: TelnetSession, log message: String) {}
    func telnetSessionMSSPData(_ session: TelnetSession) -> [(key: String, value: String)] { [] }
}
