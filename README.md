# Driverforge Control4 SDK

The library a Control4 driver vendors to talk to Driverforge. It captures errors, event timings and logs from the driver's Control4 event handlers and forwards them to the Anvil agent.

This repository is the **SDK source** — it is for people working on the SDK itself. **To install and use the SDK in a driver, see the docs: <https://go.driverforge.com/sdk>.**

Targets **Control4 OS 3.3.1 or newer**. Below that the SDK disables itself at load and the host driver runs exactly as it would with no SDK vendored, so a driver carrying it is safe to install anywhere.

MIT licensed.

## Repository layout

| Path | |
| --- | --- |
| `src/` | SDK sources — `harness.lua` (the public `Driverforge` and `Anvil` API), `client.lua` (core client), `agent_verify.lua`, `rs256.lua`, `queue.lua`, `stacktrace.lua`, `version.lua` |
| `spec/` | [busted](https://lunarmodules.github.io/busted/) test suite |
| `bin/` | build tooling — `bin/build` bundles `src/` into a single `dist/driverforge-sdk.lua` |
| `squishy` | squish manifest |

## Development

### Lua compatibility

The SDK targets the **Control4 runtime: stock LuaJIT** — not vanilla Lua 5.1, and not a `LUA52COMPAT` build. That means:

- LuaJIT's always-on 5.2 features are relied upon: `xpcall(f, handler, ...)` with arguments (silently dropped on vanilla 5.1) and `debug.getlocal(func, i)` with a function argument (errors on vanilla 5.1)
- the opt-in 5.2 library aliases are **absent**: use the 5.1 spellings — `unpack`, not `table.unpack`, which is nil on the controller

Contributions must hold to that intersection. Beware that busted's dependency chain aliases `table.unpack = unpack` at spec time, so a stray `table.unpack` passes the test suite and still crashes on the controller — specs covering vararg plumbing should nil the alias first (see the `SetTimer` specs).

With Lua 5.1 (or LuaJIT) and [LuaRocks](https://luarocks.org) installed, add the test runner:

```sh
luarocks install busted
```

### Build

```sh
./bin/build      # squishes src/ -> dist/driverforge-sdk.lua
```

If [`squish`](https://github.com/LuaDist/squish) isn't on your `PATH`, `bin/build` automatically runs the build inside the toolchain image (`ghcr.io/driverforge/anvil-lua`) — docker is the only local prerequisite.

### Test

```sh
busted spec/
```

Pass a path to run a single spec file.

## License

[MIT](LICENSE). Bundles a modified copy of StackTracePlus — see [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES.md).

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
