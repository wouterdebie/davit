# Davit

**A native macOS UI for Apple's [container](https://github.com/apple/container) platform** — think OrbStack/Docker Desktop, but for the Linux-containers-as-lightweight-VMs stack Apple ships for Apple silicon.

> A *davit* is the shipboard crane that hoists cargo and small craft over the side — which is more or less what this app does with your containers.

Built entirely in SwiftUI (no Electron, no web views). Davit links Apple's own
**`ContainerAPIClient`** library and talks to `container-apiserver` **directly over XPC** —
the same wire path the `container` CLI uses. The CLI binary is never invoked: lists,
lifecycle, live stats, log streaming, image pulls, volume/network management, the
in-terminal shell (`davit exec`), and even launchd service bootstrap all go through the API.

## Features

- **Dashboard** — service status with one-click start/stop, resource counts, disk usage with reclaimable-space cleanup menu, live aggregate CPU chart across running containers.
- **Containers** — list with live CPU/memory/IP per row, start/stop/kill/restart/delete, prune, search, and **Edit & Recreate** (containers are immutable on this platform, so "editing" opens the Run sheet prefilled with the container's ports/env/mounts/resources/network — with the image's entrypoint/CMD/env subtracted so only *your* customizations show — and replaces it on confirm). Detail view with:
  - *Overview*: image, command, platform, resources, network (IP/MAC/gateway/hostname), published ports with "Open in Browser", mounts, environment, labels.
  - *Logs*: streaming `-f` follow mode, boot-log toggle, tail selector, copy.
  - *Stats*: live CPU% and memory charts (Swift Charts), process count, network I/O.
  - *Inspect*: pretty-printed raw JSON.
  - *Terminal*: opens an interactive shell in Terminal/iTerm (`davit exec` over XPC).
- **Images** — pull with streaming progress, run-from-image, tag, delete, prune; per-image platform variants, size, digest, "used by" containers.
- **Volumes** — create (with size), delete, prune, reveal backing image in Finder, in-use badges.
- **Networks** — create (subnet / internal), delete, prune, attached-container counts.
- **Run Container sheet** — image picker, name, command, ports, env vars, volume/bind mounts, CPU/memory limits, network selection.
- **Menu bar extra** — service status, per-container quick actions from anywhere.
- **Open at login** — optional launch-to-menu-bar at login (Settings → General), via `SMAppService`.
- **In-app updates** — checks GitHub Releases daily (or on demand from About); one click downloads the new version, verifies its Developer ID signature (team must match), swaps the bundle atomically with rollback, and relaunches. `Davit update check|install` headless.
- **Settings** — platform install-root override and refresh interval (General), plus a full **platform configuration editor** (Platform tab): default container CPUs/memory, registry, local DNS domain, builder resources/Rosetta, and advanced knobs (kernel, init image, machine). Only values differing from install defaults are written to `~/.config/container/config.toml`, `[plugin.*]` sections are preserved, every save is validated through the platform's own config loader before commit, and the result is published to the app root immediately — container defaults/registry/DNS apply to new operations right away, daemon-side settings after a service restart (button provided).

## Requirements

- Apple silicon Mac, macOS 15+ (macOS 26 recommended — matches `container` 1.0)
- [apple/container](https://github.com/apple/container/releases) installed (or vendored, see below)

## Releases

Tagging `v*` triggers a GitHub Actions workflow that builds the app on a macOS
runner and attaches `Davit-<version>.zip` (+ sha256) to a GitHub Release.

With these repository secrets set, releases are Developer ID signed (hardened
runtime) and notarized, so they open like any other app:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | base64 of the exported "Developer ID Application" cert (`base64 -i cert.p12`) |
| `MACOS_CERT_PASSWORD` | the .p12 export password |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | 10-char team id (developer.apple.com → Membership) |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password from appleid.apple.com |

Without the secrets, builds fall back to ad-hoc signing and the release notes
include the `xattr -dr com.apple.quarantine` workaround.

## Install

```sh
brew install wouterdebie/tap/davit
```

(Homebrew 6 asks you to trust third-party taps on first use: `brew trust wouterdebie/tap`.)
Or download the signed zip from [Releases](https://github.com/wouterdebie/davit/releases/latest) / [davit.app](https://davit.app).

## Build & run

```sh
scripts/bundle.sh        # builds release binary + assembles dist/Davit.app
open dist/Davit.app
```

Plain `swift build` / `swift run` also works for development (no bundle, so no icon/menu-bar niceties).

## What must still be installed

The API removes the CLI dependency, **not** the platform dependency: `container-apiserver`
and its runtime/network plugin binaries are host launchd services that the library only
talks to. Davit resolves the platform install root in this order:

1. custom install root from Settings
2. a Davit-managed install at `~/Library/Application Support/dev.wouter.davit/platform/<version>`
3. `/usr/local` (the official installer)
4. vendored inside the app at `Davit.app/Contents/Resources/vendor`

**In-app install:** when no platform is found, the onboarding screen offers one-click
install — Davit downloads Apple's signed installer pkg (with a live progress bar),
verifies the code signature, extracts the payload into the managed root (no
administrator rights needed, unlike the official installer), and bootstraps the
services from there. Settings → General can then also install a `container` shell
command: a wrapper in `/usr/local/bin` that pins `CONTAINER_INSTALL_ROOT` to the
managed root before exec'ing the real CLI (one admin prompt; a bare symlink would be
wrong, since the CLI derives its install root from the unresolved executable path). The managed copy sits
above `/usr/local` in the resolution order on purpose: it always matches the client
version the app links, so a newer system daemon can't break XPC compatibility.
Also available headless: `Davit platform install|remove`.

To ship a fully self-contained app that works without the system installer:

```sh
scripts/vendor.sh 1.0.0        # downloads the official signed .pkg, extracts payload into Vendor/container
scripts/bundle.sh --vendor     # bundles it into the app
```

Service start/stop is implemented in-process (LaunchPlist + ServiceManager from
`ContainerPlugin` — the same code `container system start` runs), pointed at whichever
install root was resolved. Kernel and init-image installation are handled
non-interactively on first start. App data lives in the standard
`~/Library/Application Support/com.apple.container/`, so Davit and the CLI (if
installed) always see the same containers.

**Version pinning:** the SPM dependency on apple/container is pinned `exact: "1.0.0"` to
match the daemon; client and apiserver ship in lockstep and the XPC protocol is not a
stable public API. When the installed platform updates, bump the pin and rebuild.

Trade-offs of vendoring, for the record: the bundle grows by ~150 MB, you own the
update cadence of the toolchain, and the launchd services are registered from inside
the app bundle (so moving/deleting the app orphans them until `container system stop`).
The default remains "use the system install" because the official pkg keeps services
under `/usr/local` and updates independently.

## Binary modes

The app binary doubles as a small tool:

```sh
Davit exec <container-id>        # interactive TTY shell into a container (used by "Open Terminal")
Davit selftest                   # end-to-end test of the XPC service layer against the live daemon
Davit system start|stop          # bootstrap / tear down the container launchd services
Davit platform install|remove    # download + verify Apple's signed pkg into an app-managed install root
Davit --snapshot /tmp/shots      # render every screen to PNGs via ImageRenderer (no screen-recording permission)
```

## Architecture

```
Sources/ContainerStack/
  Main.swift            entry point + exec/selftest/system binary modes
  Backend.swift         XPC service layer on ContainerAPIClient: ContainerService facade,
                        SystemController (launchd bootstrap), LogStreamer (FileHandle tail/follow),
                        PullProgressModel, TerminalLauncher, platform install resolution
  Models.swift          view models mapped from ContainerResource types (views stay decoupled
                        from the unstable library API)
  AppState.swift        @MainActor store: polling (4s data / 2s stats), CPU% derivation, actions
  SnapshotDriver.swift  --snapshot harness
  App.swift             SwiftUI scenes, menu bar extra
  Views/                Shell (sidebar), Dashboard, Containers, ContainerDetail, Images,
                        VolumesNetworks, Sheets (run/pull/create), Settings, Components
```

Stats note: the daemon reports cumulative `cpuUsageUsec`; Davit derives CPU% from deltas
between polls, normalized to wall-clock time (100% = one full core).
