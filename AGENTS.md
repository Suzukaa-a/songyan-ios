# Project working preferences

- For physical iPhones and iPads, only build, sign, and install the requested app update. Do not launch apps, mirror the screen, interact with the device, or run tests on it. Use local tests and isolated simulators for verification; confirm installation through installation results and app metadata.
- Never connect screen mirroring, including while investigating logs: it can make the iPhone treat the connection as an external keyboard and suppress the software keyboard. Retrieve requested diagnostics through read-only device APIs or CLI commands.
- Never use `devicectl device copy to --remove-existing-content` on a physical device. It can clear the entire selected app or App Group container even when `--destination` names a subdirectory. It must not be used to clean diagnostic logs.
- A failed device file operation may already have changed data. Do not report cleanup success from a missing directory alone, and do not retry a destructive operation after an error.
- Before choosing a distribution version/build number, check this app's latest TestFlight builds in the connected Apple Developer team. Continue that version/build sequence; do not use timestamps or the project's old default version as a substitute.
