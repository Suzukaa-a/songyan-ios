# Security policy

Please report security problems privately with GitHub's private vulnerability
reporting (the "Report a vulnerability" button on this repository's Security
tab), not in a public issue. Include the app version, the iOS version and steps
to reproduce. Fixes land on `main`; there are no separately maintained release
branches.

## Script runtime

User scripts are untrusted input. They run inside the keyboard extension (and
the `HostApp` try box) in a pinned QuickJS-ng runtime built from
[Tools/Script](Tools/Script), with host-injected heap, time, request and input
limits, a fresh environment per run and no persistent storage. A script cannot
draw UI, load external code, start a process, refer to another script or update
itself. `fetch` is performed by the host callback, which only allows the hosts
the script declared with `@connect` and refuses cross-host redirects;
networking scripts require Full Access. The extension's own Rime, layout and UI
code never initiates a request. Script entry points are hidden in password
fields, and secrets live in the Keychain — never in the script file or its JSON
state.
