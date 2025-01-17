[![C CI](https://github.com/ncmud/mth/actions/workflows/c.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/c.yml) [![Swift](https://github.com/ncmud/mth/actions/workflows/swift.yml/badge.svg)](https://github.com/ncmud/mth/actions/workflows/swift.yml)

# MTH (Mud Telopt Handler)

Telnet handler which supports the
following TELNET options.

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

MTH has a permissive license, just leave the copyright notice in the
original sources, otherwise you can do as you please with it.

MTH will run stand alone and by default opens a connection on port
4321 to which a telnet / mud client can connect. This is primarily
there so you can test the code and provide you with an example
implementation.

Client side MCCP3 support is currently only supported by TinTin++.

## Building standalone

`$ cd Sources/mth`

and build the binary:

`$ make .`

## Incorporating via SPM

Add the following to your Package.swift:

```swift
.package(url: "https://github.com/ncmud/mth.git", branch: "trunk")
```

Incorporate "mth" into your targets dependencies:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        "mth",
    ]
),
```

