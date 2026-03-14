public protocol TelnetClientDelegate: AnyObject {
    /// Write raw bytes to the server connection.
    func write(data: [UInt8])

    /// Called when the server changes echo mode.
    /// When `enabled` is true, the client should echo locally.
    /// When false, the server is echoing (password mode).
    func onLocalEchoChanged(enabled: Bool)

    /// Called when GMCP subnegotiation completes.
    func onGMCPNegotiated()

    /// Called when a GMCP message is received from the server.
    func onGMCPReceived(module: String, json: String)

    /// Called when an MSDP variable is received from the server.
    func onMSDPVariable(name: String, value: String)

    /// Called when a prompt marker (GA or EOR) is received.
    func onPromptReceived()

    /// Called when a BEL character is received.
    func onBellReceived()

    /// Log a diagnostic message.
    func log(message: String)
}

public extension TelnetClientDelegate {
    func onGMCPNegotiated() {}
    func onBellReceived() {}
    func log(message: String) {}
}
