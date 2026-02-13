[![C CI](https://github.com/ncmud/mth/actions/workflows/c.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/c.yml) [![Swift](https://github.com/ncmud/mth/actions/workflows/swift.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/swift.yml)

# MTH (Mud Telopt Handler)

A Swift library for handling telnet option negotiation in MUD servers. Supports the following telnet options:

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

Also includes `MTHColor`, a color code substitution library supporting ANSI-16, xterm-256, and true color output.

## Usage

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

### TelnetSession

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

## Platforms

macOS and Linux. Requires system zlib (present in macOS SDK and as a Swift toolchain dependency on Linux).

## License

Permissive license. Keep the copyright notice in the original sources; otherwise do as you please.
