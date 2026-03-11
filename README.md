[![C CI](https://github.com/ncmud/mth/actions/workflows/c.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/c.yml) [![Swift](https://github.com/ncmud/mth/actions/workflows/swift.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/swift.yml) [![Kotlin](https://github.com/ncmud/mth/actions/workflows/kotlin.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/kotlin.yml)

# MTH (Mud Telopt Handler)

A library for handling telnet option negotiation in MUD servers and clients. Available in C, Swift, and Kotlin. Supports the following telnet options:

```
CHARSET      - Reports the character sets supported by the client.
ECHO         - Allows toggling local echo.
EOR          - Allows prompt marking.
GMCP         - Allows MSDP event handling with JSON syntax.
MCCP2        - Allows server side compression.
MCCP3        - Allows client side compression.
MSDP         - Allows structured data exchange and event handling.
MSSP         - Reports various features supported by the server.
MTTS         - Reports various features supported by the client.
NAWS         - Reports the client's window size.
NEW_ENVIRON  - Reports various system variables.
TTYPE        - Reports the client's terminal type.
```

Also includes color code substitution supporting ANSI-16, xterm-256, and true color output.

## Swift Usage

Add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/ncmud/mth.git", branch: "trunk")
```

Then add the libraries you need:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "MTH", package: "mth"),
        .product(name: "MTHColor", package: "mth"),
    ]
),
```

### Server-Side TelnetSession

```swift
import MTH

class MyConnection: TelnetSessionDelegate {
    let session: TelnetSession

    init() {
        session = TelnetSession(delegate: self)
        session.announceSupport()
    }

    // Called when the session has bytes to send to the client
    func telnetSession(_ session: TelnetSession, write data: [UInt8]) {
        socket.write(data)
    }

    // Called when the session wants to log a message
    func telnetSession(_ session: TelnetSession, log message: String) {
        print(message)
    }

    // Return MSSP key-value pairs for server status reporting
    func telnetSessionMSSPData(_ session: TelnetSession) -> [String: String] {
        ["NAME": "My MUD", "PLAYERS": "42"]
    }

    func onDataReceived(_ raw: [UInt8]) {
        let clean = session.processInput(raw)
        // clean contains user text with telnet sequences stripped
    }
}
```

### Color Substitution

```swift
import MTHColor

let output = substituteColor("^RBold Red ^ggreen^x", depth: .trueColor)
```

## Kotlin Usage

The Kotlin package provides both server-side and client-side telnet handling. Add the dependency via a Gradle composite build or git submodule:

```kotlin
// settings.gradle.kts
includeBuild("path/to/mth/kotlin") {
    dependencySubstitution {
        substitute(module("mth:mth-core")).using(project(":mth-core"))
        substitute(module("mth:mth-color")).using(project(":mth-color"))
    }
}
```

```kotlin
// build.gradle.kts
dependencies {
    implementation("mth:mth-core")  // telnet protocol handling
    implementation("mth:mth-color") // color substitution
}
```

### Client-Side (for MUD clients like Android apps)

The client session handles the inverse of server-side negotiation: it receives WILL/DO from the server and responds appropriately.

```kotlin
import mth.core.client.TelnetClientDelegate
import mth.core.client.TelnetClientSession

class MyConnection : TelnetClientDelegate {
    val session = TelnetClientSession(
        delegate = this,
        terminalType = "MyMudClient",
        windowWidth = 80,
        windowHeight = 24
    )

    override fun write(data: ByteArray) {
        socket.write(data)  // send to server
    }

    override fun onLocalEchoChanged(enabled: Boolean) {
        // toggle local echo (e.g. hide password input)
    }

    override fun onGMCPReceived(module: String, json: String) {
        // handle GMCP data from server (e.g. "Char.Vitals" with HP/mana JSON)
    }

    override fun onMSDPVariable(name: String, value: String) {
        // handle MSDP variable updates from server
    }

    override fun onPromptReceived() {
        // server sent EOR/GA — mark prompt boundary
    }

    fun onDataReceived(raw: ByteArray) {
        val displayText = session.processInput(raw)
        // displayText is clean text with all telnet sequences stripped
        terminal.append(displayText)
    }

    fun onWindowResized(cols: Int, rows: Int) {
        session.sendWindowSize(cols, rows)
    }
}
```

### Server-Side (for MUD servers)

```kotlin
import mth.core.server.TelnetSession
import mth.core.server.TelnetSessionDelegate

class MyServerConnection : TelnetSessionDelegate {
    val session = TelnetSession(delegate = this)

    init { session.announceSupport() }

    override fun telnetSessionWrite(session: TelnetSession, data: ByteArray) {
        socket.write(data)
    }

    fun onDataReceived(raw: ByteArray) {
        val clean = session.processInput(raw)
    }
}
```

## Platforms

- **Swift:** macOS, Linux, Windows. MCCP2/3 requires system zlib (present in macOS SDK and as a Swift toolchain dependency on Linux). On Windows, compression is compiled out; all other options work normally.
- **Kotlin/JVM:** Any platform with JDK 17+. MCCP2 uses `java.util.zip`.

## License

Permissive license. Keep the copyright notice in the original sources; otherwise do as you please.
