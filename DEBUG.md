# Debugging guide

How to run, inspect and profile Songyan on a simulator or device. Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md); modules and paths are indexed in [ARCHITECTURE.md](ARCHITECTURE.md).

Debug probes exist only in Debug builds (`#if DEBUG`). Logs and snapshots record phases, identifiers, counts and timings, never user input, candidate text or document content.

In this guide the *built-in package* is the offline input scheme bundled with the app, [Resources/BuiltinPackages/Basic](Resources/BuiltinPackages/Basic): `songyan_quanpin` (内置全拼), `songyan_flypy` (内置小鹤双拼) and their generated 14-, 18- and 9-key companions `keyboard_*`. The keyboard runs it from its own bundle when nothing is published; the host app also installs it at launch as the scheme package `songyan-builtin`, which is what 我的键盘 publishes.

## 1. Setup

- Full Xcode 27 or later, selected with `DEVELOPER_DIR` or `xcode-select`. The scripts fall back to an installed `/Applications/Xcode*.app`.
- [`axe`](https://github.com/cameroncooke/AXe) for simulator input (`axe -h` lists the commands). Only manual UI automation and `make sim-perf MODE=cold` need it.
- A dedicated simulator. Every `sim-*` script resolves it by name: `Songyan-Dev` by default, `SIM_NAME` to choose another, or `UDID` to target one directly. Use a separate `SIM_NAME` per parallel session so scripts never touch each other's simulator.

Always run the app from `make sim-stage`. Builds from `make build-simulator`, `make build-device`, CI or any `CODE_SIGNING_ALLOWED=NO` build carry no entitlements: the App Group container is `nil` and all shared data looks empty. Those builds only check that the code compiles.

## 2. Staging and commands

`make sim-stage` ([sim-stage.sh](Tools/CI/scripts/sim-stage.sh)):

1. builds `HostApp` (which embeds the keyboard extension) into `.local/dev-derived`, signed ad hoc so the App Group entitlement is embedded without a developer account;
2. checks that both the app and the extension carry the App Group entitlement;
3. creates the simulator if needed (`SIM_RUNTIME`, default the newest iOS runtime; `SIM_DEVICE_TYPE`, default `iPhone-17-Pro`), boots it and installs the app;
4. adds Songyan to the simulator's keyboard list (rebooting once the first time) and skips onboarding;
5. launches the host app and checks the `DebugProbe` environment line for `appGroup=ok`.

Options: `--no-build`, `--no-launch` (run the script directly). `CONFIGURATION=Release` stages an optimised build without Debug probes, for performance work.

| Command | Purpose |
| --- | --- |
| `make sim-stage` | Build, install and launch on the dedicated simulator |
| `make sim-log [LAST=2m] [CATEGORY=<name>]` | Stream logs of subsystem `app.songyan.ime`, or dump the last interval |
| `make sim-state` | Print the extension and host state snapshots as JSON |
| `make sim-layout LAYOUT=<qwerty26\|merged14\|merged18\|phone9\|clear>` | Force the layout the extension starts with (Debug only) |
| `make sim-probe PROBE=touch [STATE=on\|off]` | Toggle the touch-routing probe |
| `make s0-probe [S0_STEP=quickjs\|device\|device-log\|serve\|setup\|launch\|drive\|fixture\|collect\|stop]` | Run the S0 extension measurements, including the in-extension QuickJS cost, the device build/log collection, and the fixed input fixture whose recorded lengths are verified (section 7) |
| `make s0-quickjs` | Measure QuickJS cost in a plain simulator process, or build the archive a probe build links (`--library-out`; section 7) |
| `make benchmark` | Run Release XCTest/XCUITest keyboard performance tests |
| `make sim-perf [MODE=typing\|cold] [ARG=...]` | Native performance tests or cold-start diagnostics, see section 8 |

`sim-layout` and `sim-probe` write to the App Group defaults through the simulator's own `cfprefsd` and kill the extension process; the new value applies the next time the keyboard appears. Killing the extension makes iOS fall back to its own keyboard, so select Songyan again from the globe key. A layout the active input scheme does not offer falls back to `qwerty26`.

Debug-only switches the scripts read or write:

| Key | Where | Effect |
| --- | --- | --- |
| `debug.layoutOverride` | App Group defaults (`make sim-layout`) | Layout the extension starts with |
| `debug.touchProbe` | App Group defaults (`make sim-probe PROBE=touch`) | One `debugProbe touch ...` line per touch |
| `keyboard.frameTimingProbe` | Extension's own defaults | Samples panel geometry every frame for 6 s after launch (`KeyboardTiming` category); also needs the diagnostics switch (section 3) |
| `keyboard.transientAttributionProbe` | Extension's own defaults | Paints the extension's root view magenta, to tell its own drawing apart from the system keyboard window in a recording |

The last two are read from the keyboard extension's standard defaults, not the App Group, and only when the extension starts.

After staging, confirm the environment: `make sim-log LAST=2m CATEGORY=DebugProbe` should show `debugProbe env role=hostApp ... appGroup=ok`, and `role=keyboardExtension ... appGroup=ok` once the keyboard has been shown. `appGroup=unavailable` (also logged as a fault) means the build was not signed with the entitlement; stage again.

## 3. Logs

Categories of both targets are declared in [KeyboardLog.swift](Apps/SharedKeyboard/KeyboardLog.swift); packages declare their own under the same subsystem. `make sim-log` includes info and debug lines. Some categories need the lifecycle diagnostics switch, the host app's “记录键盘生命周期” toggle under Advanced (`keyboard.lifecycleDiagnosticsEnabled` in the App Group defaults; always on in Debug).

| Category | Content |
| --- | --- |
| `DebugProbe` | Environment line; `slowEngineOp` (queue wait plus run above 50 ms); touch routing when the touch probe is on |
| `KeyboardLifecycle` | Lifecycle events (`engineReady`, `routeRefresh.*`, ...). Needs the diagnostics switch |
| `KeyboardStall` | `slowAction` (main thread held 100 ms or more), `memoryWarning`, `appeared`. Needs the diagnostics switch |
| `KeyboardTiming` | Frame geometry probe (Debug); needs the diagnostics switch and `keyboard.frameTimingProbe` |
| `KeyboardExtension`, `KeyboardController`, `KeyboardPadSession` | Errors, plus routing, selection and active-resource lines at info/debug level |
| `KeyboardStorage` | App Group directory and cleanup failures |
| `KeyboardPreparation`, `KeyboardSave` | Host app: timings of keyboard preparation and save |
| `KeyboardGeometry`, `KeyboardPlacement` | Panel sizing traces (debug level) when `keyboard.geometryDiagnosticsEnabled` is set |
| `RimeReading` | `readingRefused gate=...` (debug level) when a highlighted reading is rejected |

## 4. State snapshots and signposts

Each process writes `Library/Caches/debug-state-<role>.json` in the App Group container (`role` is `keyboardExtension` or `hostApp`); `make sim-state` prints both. Fields: `phase`, `layout`, `schemaID`, `engineKind`, `isComposing`, `candidateCount`, `inputUnavailableReason`, `keyLatency` and `engineOp` (`count`, `p50Ms`, `p95Ms`, `maxMs`), `refreshCount`, `footprintMB`, `pid`, `wallClock`. Writes are throttled to one every 0.5 s, and the extension writes its first snapshot only after the keyboard has been shown. iOS may switch back to the system keyboard while an old snapshot still says `ready`, so compare `pid` and `wallClock` before trusting it.

Signpost intervals (subsystem `DebugProbe`): `key` (synchronous key handling), `engineOp` (`EngineOpQueue` wait plus run) and `refresh` (controller state publication). Attach Instruments with `xcrun xctrace record --device <udid> --template "Time Profiler" --attach <pid>`.

## 5. Driving the keyboard with `axe`

Pass `--udid` for your simulator and export `DEVELOPER_DIR` first.

- Read coordinates from the current UI (`axe describe-ui`, or a screenshot) and re-read them after each action. AXe's full tree shows the host app; `axe describe-ui --point x,y` can inspect a keyboard key. XCTest reads keyboard keys through `XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard").keys`, separately from the host app.
- Tap a key with one command, `axe touch -x <x> -y <y> --down --up --delay 0.05`. Separate `--down` and `--up` calls register as a short swipe. Host-app list rows often need `axe tap --tap-style physical`.
- Long press: `axe touch -x <x> -y <y> --down --up --delay 1.5`. `--pre-delay` waits before the press; it is not a hold.
- Judge each step by its effect (composition, candidates, committed text) rather than the command's exit code, and take a screenshot when in doubt.
- Typical flow: open the host app's “试打” (Try typing) tab, tap the text field, long-press the globe key and pick Songyan.
- Rotate an iPhone simulator without Simulator.app (Debug builds): `xcrun simctl openurl "$UDID" "songyan://debug/orientation?to=landscape"` (or `portrait`). The first call asks to open 松烟; confirm it. The keyboard stays up, so this also exercises rotation while it is visible. iPadOS ignores the request.
- If `axe` keeps failing with `No translation object returned`, restart your simulator's bridge: `xcrun simctl spawn "$UDID" launchctl kickstart -k user/foreground/com.apple.CoreSimulator.bridge`. If touches stop reaching the extension after a reinstall, `xcrun simctl shutdown` and `boot` the simulator.

## 6. Host app log

The host app appends install, import and selection results to `Library/Application Support/host.log` in its container (`HostLog` in [HostStorage.swift](Apps/HostApp/HostStorage.swift)). Read it with `cat "$(xcrun simctl get_app_container "$UDID" app.songyan.ime data)/Library/Application Support/host.log"`, or in the app under 设置 > 高级 > 诊断日志.

## 7. Adding a probe

Add probes to `DebugProbe` in [KeyboardLifecycleDiagnostics.swift](Apps/SharedKeyboard/KeyboardLifecycleDiagnostics.swift) under `#if DEBUG`. On hot paths (key handling, candidate refresh) emit only signposts and counters: no disk writes and no string building. A switch read once at extension start (like `DebugProbe.touchRoutingEnabled`) is fine; register it in [sim-probe.sh](Tools/CI/scripts/sim-probe.sh). Keep probe code in separate Debug-only functions and never log user input.

### S0 measurements

The script and extension work is planned from five facts about the keyboard extension, and
`S0Probe` ([S0Probe.swift](Apps/SharedKeyboard/S0Probe.swift)) is the Debug-only probe that
records them: lengths, status codes and byte sizes only, never input text, candidate text or
Keychain values. Results are `s0Probe ...` lines on the `DebugProbe` category and
`Library/Caches/s0-probe-<role>.json` in the App Group container.

- Input context: `selectedText` and `documentContextBeforeInput`/`AfterInput` lengths in
  characters and UTF-16 units, field type and Full Access. The keyboard's appearance is sampled
  directly. Only in the S0 probe build (`SONGYAN_S0_PROBE`) do the text and selection callbacks
  also arm one debounced sample: the callback itself only counts, and the sample runs on the main
  queue 0.25 s after the burst and is logged without a file write, so typing never costs per-key
  disk IO. That also means the artifact's counters are the values at its last write while the
  per-burst samples exist only in the log. Secure-entry fields (`isSecureTextEntry`), password
  and one-time-code fields are never sampled; a skipped field logs a fixed marker only, no field
  type and no value. An ordinary Debug build samples the appearance and nothing else. Known input
  can replace driving the keyboard: `make s0-probe S0_STEP=fixture` starts the probe build with
  `SONGYAN_S0_INPUT_PROBE=1`, which opens a fixed text field that steps through ASCII at the end,
  ASCII in the middle, an ASCII selection, an empty field and a CJK caret, logging one
  `s0Probe inputFixture step=...` marker per step. The run calls
  [s0-verify-fixture.py](Tools/CI/scripts/s0-verify-fixture.py), which connects each marker to the
  next extension sample by log order (no assumed delay) and compares the recorded lengths with
  the step's expected values. It fails with distinct codes for an unreadable or empty log, no
  fixture markers (not a probe build, or the fixture never started), a step without a sample, or a
  length mismatch; the driver also fails before collecting when the keyboard never started for the
  fixture. The fixture has no password step: on this simulator, focusing a field with
  `isSecureTextEntry` or the password content type made iOS show the system keyboard, so the
  extension did not run and its sensitive-field guard could not be observed. That is a simulator
  observation only; whether a device or a particular host routes such a field to a custom keyboard,
  and what it would then expose, is not verified here. The guard stays in code as a defensive
  check, and a skipped field would log a fixed marker without any type or value.
- Keychain: the host app writes a fixed non-secret marker in the AfterFirstUnlock and
  WhenUnlocked classes twice — once without an access group, which is the process's default group
  and the control, and once with the App Group both targets already carry. The extension reads the
  default-group account (expected to miss, since the two processes' default groups are their two
  different app IDs), the App Group account with the attribute, and the same account without it;
  it also writes and reads back its own App Group item. Only `OSStatus`, byte counts and whether
  the marker came back are recorded, never the item contents. The App Group path needs no keychain
  entitlement: Apple counts the application groups among a process's keychain access groups, so
  the existing App Group is already shared and a probe build measures it without changing any
  production entitlement. A dedicated keychain access group (the Keychain Sharing capability) is
  not measured, and no keychain result here comes from a device or from a locked screen.
  `probeVersion` 3 marks these keychain fields and the engine measurements; earlier versions gave
  both sides the same account and are not comparable.
- Network: the same plaintext LAN URL and HTTPS URL are fetched from the host app as a control
  and from the extension, recording the HTTP status or URL error code and Full Access.
- App Group write: one small file is written and removed, recording whether the OS allowed it.
  This is a permission test of its own; Full Access is reported separately and is never inferred
  from it.
- Memory: `phys_footprint` and `os_proc_available_memory()` (`0` means the value is unavailable).
- Engine: what a QuickJS runtime costs the extension process itself. The engine is not part of
  the product: `make s0-probe S0_STEP=quickjs` (also the first step of `make s0-probe run`)
  builds a static archive from the tag and digest that `s0-quickjs-probe.py` records and stages
  a Debug build whose extension links it. A probe build is a single switch, `S0_PROBE_ARCHIVE`:
  the build scripts resolve it into the `S0_QUICKJS_LDFLAGS` linker setting and the
  `S0_PROBE_CONDITIONS=SONGYAN_S0_PROBE` compilation condition, which both targets compile in, so
  a probe build samples without the App Group default or a launch environment. Every other build
  leaves both settings empty: no normal build links an engine, no engine version is pinned in the
  repository, and Release contains none of this code. The archive is linked into the extension
  binary, so the code is covered by the extension's own signature; nothing is loaded from outside
  the bundle, which a device would refuse. Measurements (`engine` in the artifact, one
  `s0Probe engine ...` line per run):
  - cold start = the first `JS_NewRuntime` + `JS_NewContext` + bootstrap eval in a freshly
    launched extension process, reported as `coldStartMs` and, per run, as `runtimeMs`,
    `bootstrapMs` and `workloadMs`;
  - `phys_footprint` around each run, and the kernel-tracked `ledger_phys_footprint_peak`
    growth. Both describe this process, not the engine alone: the peak is the process's lifetime
    peak, so its growth is a lower bound once an earlier phase already peaked higher, and a run
    after another one reuses memory that the earlier runtime freed, so a per-run figure is not
    comparable with a fresh-process number. These figures are the engine's cost in this process,
    read against the extension's own limit, not a process-independent engine size;
  - `os_proc_available_memory()` before and after a run.

  The two carriers (this process and the spawned plain process) share the small and large
  workloads and the limit sweep, but only the sweep is compared across them: it records whether a
  workload still runs under a given limit, which memory reuse between runtimes or between fresh
  processes does not change. It does not choose a final limit.

`make s0-probe run` runs the whole cycle: it builds the probe engine archive and stages the
probe-linked build, writes `debug.s0Probe`, `debug.s0ProbeHTTPURL` and `debug.s0ProbeHTTPSURL`
into the App Group defaults through the simulator's `cfprefsd`, serves the plaintext URL from
the Mac's LAN address, launches the host app (which also accepts `SONGYAN_S0_PROBE=1` in its
launch environment), opens 试打 with `axe`, and copies the artifacts and matching log lines
into `.local/s0-probe/<timestamp>/`. Drive other hosts by
hand and run `make s0-probe S0_STEP=collect` afterwards. `make s0-probe S0_STEP=stop` removes
the switches and stops the server.

`make s0-probe S0_STEP=device` covers the device side: it builds the same archive for the device
slice, builds a Debug device app from the same `S0_PROBE_ARCHIVE` switch (so sampling is compiled
in and an installed build needs no switch), and packages that app with the existing ad-hoc signing
step (`package-ipa.sh --configuration Debug`) into
`.local/s0-probe/s0-probe-debug-<timestamp>.ipa`. That device build also sets
`ENABLE_DEBUG_DYLIB=NO`: the code stays in `HostApp` and `KeyboardExtension` themselves, so a
re-signer that only walks frameworks (AltStore, Sideloadly) cannot leave a `*.debug.dylib`
unsigned. Re-signing and installing that IPA works the same way as the Release IPA: import it into
the installer, let it re-sign under your team, install.

A device install cannot be handed an App Group default or a launch environment, so the two network
addresses are embedded at build time in both Info.plists: each target reads its own copy, and the
extension therefore does not have to read the shared container to know where to fetch. The report
still leaves the device through the app:

1. Name the LAN address when building (otherwise the build uses this Mac's LAN address):
   `S0_PROBE_HTTP_URL=http://192.168.1.20:8765/plain.txt make s0-probe S0_STEP=device`.
   `S0_PROBE_HTTPS_URL` overrides the HTTPS target (default `HTTPS_URL`, i.e. example.com). The
   build entry passes them as `SONGYAN_S0_PROBE_HTTP_URL` / `_HTTPS_URL`, so both Info.plists
   carry them. The script starts the plaintext server and prints the embedded URLs;
   `S0_STEP=serve` starts it on its own, `S0_STEP=stop` stops it. The Mac has to stay reachable
   at that address.
2. Install the IPA and set 允许完全访问 as the round needs: on for the network and export items,
   off for the round that measures what an extension without it can still do.
3. Use the keyboard (试打 or any text field), so the extension records its appearance.
4. Open 松烟: it copies `s0-probe-*.json` from the shared container into its own Documents
   `S0Probe` folder, if the extension could write the container. The host app already exposes
   Documents through file sharing (it is where the keyboard's files live), so artifacts leave the
   device through Files → 松烟 → S0Probe, or through Xcode's Devices window → Download Container.

A round with 允许完全访问 off is a separate S0 fact. Turn it off under Settings → 通用 → 键盘 →
键盘 → 松烟 → 允许完全访问 and use the keyboard again. What such a round can do is what the
device run has to record, so the probe writes down what actually happened instead of assuming it:
`s0Probe appGroupWrite ... ok=0|1`, `s0Probe artifact ... wrote=0 reason=noContainer` when the
container write is refused, and `s0Probe network ...` with the fetch outcome, or
`skipped=noURL` only if neither the defaults nor the extension's own Info.plist offered an
address. If the container cannot be written, that round has no artifact JSON and the log is its
only evidence; Files export then covers only rounds whose artifacts reached the container, and
the network item is still attempted because the address is embedded in the extension.
The unified log keeps the probe's notice-level `s0Probe ...` lines. Run
`UDID=<device udid> make s0-probe S0_STEP=device-log` from a terminal (device collection needs
root, so it asks for sudo) and it keeps the matching lines in
`.local/s0-probe/<timestamp>-device/probe-device.log`. It runs:

  ```sh
  sudo /usr/bin/log collect --device-udid <udid> --last 15m --output .scratch/s0-probe/device.logarchive
  /usr/bin/log show --archive .scratch/s0-probe/device.logarchive \
    --predicate 'subsystem == "app.songyan.ime" AND category == "DebugProbe"' \
    --info --debug --style compact | grep s0Probe
  ```

  `DEVICE_LOG_LAST` widens the window (for example `DEVICE_LOG_LAST=2h`) and
  `xcrun devicectl list devices` prints device UDIDs. Those flags and the predicate were checked
  against this Mac's `log` help, and the predicate was run against a real log archive; collecting
  from a paired device itself needs the device and was not run here. This Mac's
  `xcrun devicectl device info files --help` lists the domain types `temporary`,
  `appDataContainer`, `appGroupDataContainer` and `systemCrashLogs` (the container domains need
  their domain identifier, for example the bundle ID); reading any of them from an actual device
  was not run here, so how a device's shared container is collected stays unverified.

Only a probe build fills those Info.plist keys; `Identity.xcconfig` defaults both to empty, so
Release and ordinary Debug describe nothing and no code reads them (the whole probe file is
Debug-only and the sampling switch is a probe-build condition). What this checkout can check is
compiling, linking, embedding, packaging, signing and re-signing, plus the address lookup and
export code paths in the simulator; whether a device samples, reaches the network without Full
Access, writes the container without it, or exports, still needs the device, so no device
measurement exists. Release builds never link the archive.

This staging does not reproduce the device's Full Access boundary: with Full Access reported
off, the probe recorded a successful extension fetch and a successful App Group write, while
the platform requires Full Access for both ([ARCHITECTURE.md](ARCHITECTURE.md) section 11). A
simulator run therefore describes the code path only; the boundary itself needs a device. The
engine numbers have the same limit: a simulator app extension has no device extension memory
limit, so its footprint deltas describe cost and its `availableBytes` (`0`, unavailable) is not
a budget. The Keychain probe uses each process's default access group, so a shared Keychain
access group is untested; the extension saw the host's item as not found on the simulator.
Peak and headroom figures stay what they measure — a cost in this process — and are not a
device limit until a signed device run reproduces them.

`make s0-quickjs` ([s0-quickjs-probe.py](Tools/CI/scripts/s0-quickjs-probe.py)) answers the
running-cost half without touching the app: it builds a pinned QuickJS-ng for arm64 iOS
simulator in `.scratch/s0-quickjs/`, runs it through `xcrun simctl spawn` and writes
`.local/ci/s0-quickjs/report.json`. Every measured run is a fresh process, so its footprint
difference belongs to that process; the memory-limit sweeps create several runtimes inside one
process on purpose and therefore report only whether the script runs and the exception text —
an out-of-memory failure and a script error stay distinguishable — and report no footprint. The
archive digest is checked against the recorded one and a mismatch is refused. A spawned process
is not an app extension, so the numbers are engine-cost evidence rather than an extension budget,
and the tag is a probe input, not a product version pin.

The same engine source and workloads also feed the in-extension measurement: add
`--library-out <path>` and the script compiles the engine plus its probe entry points into a
static archive for that platform (`--platform simulator` or `device`) instead of running the
plain-process driver. It does not add a product version: only a probe build links the archive,
through `S0_QUICKJS_LDFLAGS`. The archive is rebuilt only when the tag, digest or probe source
changes, so repeated probe runs reuse it.

## 8. Performance

`make benchmark` runs the shared `KeyboardPerformance` scheme through `xcodebuild test`. [sim-benchmark.sh](Tools/CI/scripts/sim-benchmark.sh) stages an ad-hoc signed Release build with `SONGYAN_PERF`, disables coverage, and runs [KeyboardPerformanceTests.swift](Tests/Performance/KeyboardPerformanceTests.swift) serially. Ordinary builds omit these performance signposts and the fixture reset button.

The fixture uses a dedicated `Songyan-Perf-Isolated` iPhone 17 Pro simulator on iOS 27.0, the built-in full pinyin scheme on its 26-key layout and, for the 9-key case, on its 9-key layout (added for that test and removed afterwards). It verifies that typing `nihao` commits `你好` through the real extension and engine; the other cases hold Delete through a composition and type on the 9-key layout. Each measurement runs 10 iterations after XCTest's warm-up:

- `appearance`: `viewWillAppear` through the end of `viewDidAppear`.
- `key`: synchronous key dispatch in `KeyboardController.handle`.
- `engineOp`: queue wait, engine execution and asynchronous return through `EngineOpQueue`.
- `refresh`: controller state publication.
- `keyToHost`: key press to the host text it causes, including the engine hops; it ends after the last proxy write the key caused, once no key is decoding and no reading is pending.

These intervals describe their named code boundaries; first-frame and touch-to-visible latency need separate frame instrumentation. Results and raw samples are in `.local/ci/keyboard-performance-*/<run>/KeyboardPerformance.xcresult` and `metrics.json`. Compare repeated runs on the same simulator, runtime and build settings before drawing conclusions about a change. `make sim-perf MODE=typing ARG=<label>` runs the same native suite with a result label.

[benchmark.yml](.github/workflows/benchmark.yml) runs the same suite for every pushed `v*` release tag and on manual dispatch, using Xcode 27.1 and a fresh iOS 27.0 iPhone 17 Pro simulator. It publishes medians and maxima in the job summary and retains the raw `.xcresult`, JSON metrics and build logs for seven days.

`make sim-perf MODE=cold ARG=<runs>` retains the AXe lifecycle diagnostic: restart the extension, open “试打” and print launch, appearance and `engineReady` events. Stage Release first with `CONFIGURATION=Release make sim-stage`. Its output is a diagnostic timeline, not a performance assertion. Results go under `.local/ci/perf-cold/`.

For memory use `footprint <extension pid>` on hardware. Simulator memory does not match a device.

For simulator measurements, find the `KeyboardExtension` PID whose executable path contains your simulator UDID, then run `footprint -p <pid> --noCategories --format bytes --json <output.json>`. In the JSON, `processes[].auxiliary.phys_footprint` is the current value and `phys_footprint_peak` is the kernel peak for that process lifetime. Keep the PID and simulator identity with the result. `keyAreaRenderToken` in `KeyboardPanelView` decides when key areas are rebuilt; new input that changes key drawing must be folded into it.

## 9. Device crash logs

With the device paired and Xcode selected:

```sh
xcrun devicectl list devices
xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs
xcrun devicectl device copy from --device <udid> --domain-type systemCrashLogs \
  --source <file name> --destination .scratch/crash/
```

Look for `KeyboardExtension-*.ips` (also under `Retired/`) and `JetsamEvent-*.ips`. Each `.ips` file is a JSON header line followed by a JSON body; `termination` and `faultingThread` in the body give the cause. Jetsam reports list the extension's memory footprint. Symbolicate against the dSYMs of the exact build by matching the binary UUID.

For the unified log, run in your own terminal (it needs `sudo`):

```sh
sudo log collect --device-udid <udid> --start '<YYYY-MM-DD HH:MM:SS>' --output .scratch/device.logarchive
/usr/bin/log show --archive .scratch/device.logarchive --predicate 'process == "KeyboardExtension"'
```

App `Logger` lines at debug level are not kept on a device; UIKit, `launchd` exit and memory-warning lines usually are. Termination code `0xdead10cc` means the extension was suspended while holding a file lock; the `launchd` exit line names the file.

## 10. Engine harnesses

The build scripts print the executable path on their last line and check the installed simulator slice against [RimeKitArtifact.json](Packages/RimeBridge/RimeKitArtifact.json). Run the executables on a booted simulator with fresh directories under `.scratch/`.

- **Grammar-model ranking**: build with [41-build-grammar-simulator.sh](Tools/BuildRimeIOS/scripts/41-build-grammar-simulator.sh), then run [verify-grammar-ranking.py](Tools/BuildRimeIOS/scripts/verify-grammar-ranking.py) with `--harness`, `--shared` (see [Tests/Fixtures/GrammarRanking](Tests/Fixtures/GrammarRanking)), `--model`, `--fixture` and `--simulator <UDID>`. It changes only `grammar/language` between two runs and requires the model to load, score candidates and change their order. Both runs set `max_homophones: 8`; with the default of 1, alternatives are pruned before the model sees them.
- **Snapshot failure recovery**: `python3 Tools/BuildRimeIOS/scripts/build-snapshot-recovery-probe.py`, then `xcrun simctl spawn <UDID> <printed path> <repo>/Resources/BuiltinPackages/Basic <fresh .scratch dir> -`. It compiles the real `RimeEngine`, `RimeBackend` and `InputSession` with test-only failpoints and passes with exit code 0 and `ALL PASS snapshot recovery`.
- **Learning backup**: format and merge tests run with `python3 Tests/IOS/test_learning_backup_format.py`; the real-engine probe is built by [build-learning-backup-probe.py](Tools/BuildRimeIOS/scripts/build-learning-backup-probe.py) and run with `xcrun simctl spawn <UDID> <exe> <repo>/.scratch/learning-backup-<suffix>`. [build-learning-engine-io-probe.py](Tools/BuildRimeIOS/scripts/build-learning-engine-io-probe.py) exercises write failures against a real LevelDB user dictionary.
- **Host OpenCC tool**: [14-build-host-opencc.sh](Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh) builds the pinned macOS `opencc_dict` into `.local/ios-engine/prefix-mac` (`--check` verifies it). Fetch sources first with [01-fetch.sh](Tools/BuildRime/scripts/01-fetch.sh). [11-build-deps.sh](Tools/BuildRimeIOS/scripts/11-build-deps.sh) runs it automatically.

## 11. Troubleshooting

- **Empty shared data or a `nil` App Group container**: the app came from an unsigned build; use `make sim-stage`.
- **Songyan missing from the globe menu**: `AppleKeyboards` must hold the full keyboard list and `AppleKeyboardsExpanded` must be set (`sim-stage` does both); reboot the simulator after changing them by hand.
- **An imported scheme needs an engine component Songyan lacks**: the host app names the missing component, keeps the previous configuration and leaves the current keyboard in place.
- **`sandbox_apply: Operation not permitted`** from nested `sandbox-exec` or Swift macro processes: if you trust the dependency sources, set `CI_SWIFTPM_DISABLE_SANDBOX=1` for that run (for example `CI_SWIFTPM_DISABLE_SANDBOX=1 make sim-stage`). Build caches live under `.local/`; the scripts set a project-local `CFFIXED_USER_HOME` and never change global Xcode preferences.
