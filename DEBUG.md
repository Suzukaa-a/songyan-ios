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

## 8. Performance

`make benchmark` runs the shared `KeyboardPerformance` scheme through `xcodebuild test`. [sim-benchmark.sh](Tools/CI/scripts/sim-benchmark.sh) stages an ad-hoc signed Release build with `SONGYAN_PERF`, disables coverage, and runs [KeyboardPerformanceTests.swift](Tests/Performance/KeyboardPerformanceTests.swift) serially. Ordinary builds omit these performance signposts and the fixture reset button.

The fixture uses a dedicated `Songyan-Perf-Isolated` iPhone 17 Pro simulator on iOS 27.0, the built-in full pinyin scheme and its 26-key layout. It verifies that typing `nihao` commits `你好` through the real extension and engine. Each measurement runs 10 iterations after XCTest's warm-up:

- `appearance`: `viewWillAppear` through the end of `viewDidAppear`.
- `key`: synchronous key dispatch in `KeyboardController.handle`.
- `engineOp`: queue wait, engine execution and asynchronous return through `EngineOpQueue`.
- `refresh`: controller state publication.

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
