package mth.core.client

interface TelnetClientDelegate {
    /** Send raw bytes to the server socket. */
    fun write(data: ByteArray)

    /** Local echo state changed due to server ECHO negotiation. */
    fun onLocalEchoChanged(enabled: Boolean)

    /** GMCP has been negotiated. Called once when server's WILL GMCP is accepted. */
    fun onGMCPNegotiated() {}

    /** GMCP data received from server. */
    fun onGMCPReceived(module: String, json: String)

    /** MSDP variable update received from server. */
    fun onMSDPVariable(name: String, value: String)

    /** Server sent EOR or GA prompt marker. */
    fun onPromptReceived()

    /** MSSP data received from server. */
    fun onMSSPReceived(data: Map<String, String>) {}

    /** Server sent BEL (0x07) character. */
    fun onBellReceived() {}

    /** Log a diagnostic message. */
    fun log(message: String) {}
}
