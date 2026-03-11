package mth.core.server

interface TelnetSessionDelegate {
    fun telnetSessionWrite(session: TelnetSession, data: ByteArray)
    fun telnetSessionLog(session: TelnetSession, message: String) {}
    fun telnetSessionMSSPData(session: TelnetSession): List<Pair<String, String>> = emptyList()
}
