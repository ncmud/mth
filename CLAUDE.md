# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Task Management

Use `chainlink` (https://github.com/dollspace-gay/chainlink, already on PATH) to manage tasks for yourself. Initialize with `chainlink init` if `.chainlink/` doesn't exist yet. Use `chainlink create`, `chainlink quick`, `chainlink list`, `chainlink next`, etc. to track work items, blockers, and progress.

## What This Is

MTH (Mud Telopt Handler) — a C library for telnet protocol handling in MUD servers. Packaged as a Swift Package (SPM) exposing two C library targets. There is no Swift code; Swift consumes the C API directly via C interop.

## Build

```bash
# Swift Package Manager (primary, runs on macOS)
swift build -v

# Standalone C build (runs on Linux/macOS, produces test server on port 4321)
cd Sources/mth && make
```

CI runs both: Swift build on macOS, C build on Ubuntu (see `.github/workflows/`).

## Testing

No test suite. Verification is build-only: `swift build -v` must succeed.

The standalone `make` build produces an executable that opens port 4321 for manual testing with a telnet/MUD client.

## Git

- **Main branch:** `trunk`
- PRs target `trunk`

## Architecture

Two SPM targets defined in `Package.swift`:

### `mth` — Telnet protocol handler
- **telopt.c** — Core telnet option negotiation state machine. Table-driven parsing for 11+ telnet options (CHARSET, ECHO, EOR, GMCP, MCCP2/3, MSDP, MSSP, MTTS, NAWS, NEW_ENVIRON, TTYPE). MCCP2/3 compression via zlib.
- **msdp.c** — MUD Server Data Protocol. Binary-search variable table, bidirectional JSON/MSDP conversion, batched and instant updates.
- **mth.c** — Library init/teardown (`init_mth`, `init_mth_socket`, `uninit_mth_socket`), telnet table setup.
- **net.c** — Socket creation, connection handling, main event loop (standalone mode only).
- **mud.c** — `descriptor_printf`, `write_to_descriptor` wrappers.

### `mthcolor` — Terminal color substitution
- **color.c** — Single function `substitute_color(input, output, colors)`. Supports 16/256/4096 color modes with automatic downgrade. MUD 32-color codes (`^a`-`^z`, `^A`-`^Z`), xterm 256 codes, true color via `<F000>`-`<FFFF>` (foreground) and `<B000>`-`<BFFF>` (background).

### Key data structures (`mth.h`, `mud.h`)
- `mth_data` — Per-connection telnet state: MSDP data, terminal type, MTTS flags, window size, compression streams.
- `mud_data` — Global server state: client list, port, table sizes, compression buffer.
- `descriptor_data` — Network connection: socket fd, mth_data pointer, host, linked list.

### Integration pattern
The library sits between raw sockets and a MUD's command interpreter. See `INSTALL` for the 7-step integration guide: init, socket lifecycle, `translate_telopts()` for input, `write_mccp2()` for output, periodic `msdp_send_update()`.

### Customization points
Macros in `mth.h` (`RESTRING`, `STRFREE`, `STRALLOC`) and constants in `mud.h` (`MAX_INPUT_LENGTH`, `MUD_PORT`, etc.) are meant to be adapted to the consuming MUD's conventions.
