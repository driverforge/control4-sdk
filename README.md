# Driverforge Control4 SDK

[![CI](https://badge.buildkite.com/13f54e0cbc941b049cfb50f2e2da70d92a1b26dac4c5514849.svg?branch=main)](https://buildkite.com/kmsgroup/control4-sdk)

The library a Control4 driver vendors to talk to Driverforge. It captures errors, event timings and logs from the driver's Control4 event handlers and forwards them to the Anvil agent.

This repository is the **SDK source** — it is for people working on the SDK itself. **To install and use the SDK in a driver, see the docs: <https://go.driverforge.com/sdk>.**

Targets **Control4 OS 3.3.1 or newer**. Below that the SDK disables itself at load and the host driver runs exactly as it would with no SDK vendored, so a driver carrying it is safe to install anywhere.

MIT licensed.

## Repository layout

| Path | |
| --- | --- |
| `src/` | SDK sources — `harness.lua` (the public `Driverforge` and `Anvil` API), `client.lua` (core client), `agent_verify.lua`, `rs256.lua`, `queue.lua`, `diagnostics.lua`, `version.lua` |
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
luarocks install lua-cjson
luarocks install openssl
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

The RS256 tests run pinned Wycheproof vectors, fresh OpenSSL signatures and
bounded malformed inputs. OpenSSL is a test dependency; verification remains
pure Lua. Missing test dependencies fail the conformance suite. To check the
verifier on both supported runtimes (with the rocks available to each):

```sh
busted --lua=lua spec/rs256_spec.lua spec/rs256_conformance_spec.lua spec/rs256_fuzz_spec.lua
busted --lua=luajit spec/rs256_spec.lua spec/rs256_conformance_spec.lua spec/rs256_fuzz_spec.lua
```

Corpus provenance and checksums are in `spec/fixtures/wycheproof/SOURCE.txt`.
The tests require canonical RFC 8017 encoding and reject the corpus's legacy
missing-NULL encoding. Passing these tests is not a cryptographic audit.

The repeated conformance calculations temporarily suspend LuaCov's line hook;
the ordinary verifier specs still collect coverage. Instrumenting every RSA
arithmetic iteration across the corpus otherwise exceeds the CI time limit.

## License

[MIT](LICENSE). Test-fixture licenses are listed in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES.md).

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
