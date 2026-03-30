package mth.core

object TelnetCommand {
    const val IAC: Byte = 0xFF.toByte()  // 255
    const val DONT: Byte = 0xFE.toByte() // 254
    const val DO: Byte = 0xFD.toByte()   // 253
    const val WONT: Byte = 0xFC.toByte() // 252
    const val WILL: Byte = 0xFB.toByte() // 251
    const val SB: Byte = 0xFA.toByte()   // 250
    const val GA: Byte = 0xF9.toByte()   // 249
    const val EL: Byte = 0xF8.toByte()   // 248
    const val EC: Byte = 0xF7.toByte()   // 247
    const val AYT: Byte = 0xF6.toByte()  // 246
    const val AO: Byte = 0xF5.toByte()   // 245
    const val IP: Byte = 0xF4.toByte()   // 244
    const val BREAK: Byte = 0xF3.toByte() // 243
    const val DM: Byte = 0xF2.toByte()   // 242
    const val NOP: Byte = 0xF1.toByte()  // 241
    const val SE: Byte = 0xF0.toByte()   // 240
    const val EOR: Byte = 0xEF.toByte()  // 239
    const val ABORT: Byte = 0xEE.toByte() // 238
    const val SUSP: Byte = 0xED.toByte()  // 237
    const val xEOF: Byte = 0xEC.toByte()  // 236

    fun isCommand(c: Byte): Boolean = (c.toInt() and 0xFF) >= (xEOF.toInt() and 0xFF)
}

object TelnetOption {
    const val ECHO: Byte = 1
    const val SGA: Byte = 3
    const val TTYPE: Byte = 24
    const val EOR: Byte = 25
    const val NAWS: Byte = 31
    const val NEW_ENVIRON: Byte = 39
    const val CHARSET: Byte = 42
    const val MSDP: Byte = 69
    const val MSSP: Byte = 70
    const val MCCP1: Byte = 85.toByte()
    const val MCCP2: Byte = 86.toByte()
    const val MCCP3: Byte = 87.toByte()
    const val MSP: Byte = 90.toByte()
    const val MXP: Byte = 91.toByte()
    const val GMCP: Byte = 0xC9.toByte() // 201
}

object TelnetSub {
    const val ENV_IS: Byte = 0
    const val ENV_SEND: Byte = 1
    const val ENV_INFO: Byte = 2
    const val ENV_VAR: Byte = 0
    const val ENV_VAL: Byte = 1
    const val ENV_ESC: Byte = 2
    const val ENV_USR: Byte = 3

    const val CHARSET_REQUEST: Byte = 1
    const val CHARSET_ACCEPTED: Byte = 2
    const val CHARSET_REJECTED: Byte = 3

    const val MSSP_VAR: Byte = 1
    const val MSSP_VAL: Byte = 2
}
