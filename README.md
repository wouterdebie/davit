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
  - *Stats*: live CPU %, memory, and disk-I/O charts (Swift Charts); tiles for CPU, memory, disk space used, network, and process count.
  - *Inspect*: pretty-printed raw JSON.
  - *Terminal*: opens an interactive shell in Terminal/iTerm (`davit exec` over XPC).
  - *Files*: browse the container filesystem — navigate, download, upload, delete (over `exec` + copy in/out).
- **Images** — pull with streaming progress, **Pull Latest** to refresh any image's tag to the newest digest (context menu or image detail), run-from-image, tag, delete, prune; per-image platform variants, size, digest, "used by" containers.
- **Volumes** — create (with size), delete, prune, reveal backing image in Finder, in-use badges.
- **Networks** — create (subnet / internal), delete, prune, attached-container counts.
- **Machines** — Apple's container machines (lightweight general-purpose VMs with your home directory mounted and a stable `.machine` DNS name): create from any image with CPU/memory sizing, boot/stop, set the default, delete; detail view with configuration overview, streamed logs, live stats and inspect JSON; one-click **Terminal** into the machine's login shell; edit CPUs/memory/home-mount (applies on next boot). `Davit machine list|create|boot|stop|delete|exec|set` headless.
- **Run Container sheet** — image picker, name, command, ports, env vars, volume/bind mounts, CPU/memory limits, network selection. `Davit run [flags] IMAGE [COMMAND…]` headless (docker-style single-container run — see Binary modes) with `-d`/`--rm`/`--pull missing|always|never` and the same docker-ish flag vocabulary as compose.
- **Build images** — Images → Build Image: pick a context folder and Dockerfile, set tag/build-args, and Davit drives the platform's BuildKit builder (starting it if needed), then loads and tags the result into the image store. `Davit build -t <tag> <context-dir>` headless.
- **Compose import** — Containers → ⋯ → Import Compose File: parses a compose file, previews exactly what will be created (services in `depends_on` order, named volumes, networks, the equivalent `container run` command per service, and warnings for anything unsupported), then creates and starts the stack — honoring `healthcheck`s, `profiles`, `depends_on` conditions (`service_healthy`, `service_completed_successfully`), `env_file:`/`entrypoint:`, and `${VAR}` interpolation from the file's sibling `.env` merged under the process environment. `.env` and `env_file:` values are themselves interpolated at load time (docker parity): a double-quoted or bare value like `VAR="${HOME}/x"` expands against the process environment and earlier entries in the same/prior files, while a single-quoted value (`VAR='${HOME}/x'`) stays literal; inline comments (` # …`) are stripped docker-style, and known deviations from compose-go (backslash escapes like `\$` are not processed — use `$$`; a nested default `${A:-${B}}` keeps the default literal) are deliberate. Headless: the full lifecycle — `Davit compose plan | up [-d] [--down-on-failure] | down [-v] | ps | logs [-f\|--follow] [--tail <n>] | stop | start | restart | pull | exec <service> <command…>`, each taking `[-f <file>] [--env-file <path>] [--profile <p>]… [--verbose\|-q\|--quiet] [service…]` — autodiscovers the file like docker (`compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.yaml`, walking up parent directories; `COMPOSE_FILE` wins). `--down-on-failure` (up only) tears the containers this invocation itself created back down if the up fails partway, without disturbing already-running services it reused; `--verbose`/`-q`/`--quiet` control per-command diagnostics (mutually exclusive). Naming services scopes the command: `plan`/`up` add the dependency closure, while `stop`/`start`/`restart`/`pull`/`ps` and `down` apply to exactly the named services (docker behavior). Service discovery: the platform's DNS cannot resolve compose service names, so `up`/`start`/`restart` write managed `/etc/hosts` entries (suffixed `# davit-compose`) into every running container of the project, mapping each service and container name to its current IP — refreshed on every run, so a recreated service's new IP reaches the containers that kept running. Caveat: containers recreated outside compose keep stale entries until the next `up` or `start`; images without `/bin/sh` can't be patched (warning). Resource limits: a service without `mem_limit`/`cpus` (or `deploy.resources.limits`) gets the platform's default container memory/CPUs — configurable in Settings → Platform; since each service is its own lightweight VM, that default is reserved per container, not shared across the stack. Logging: the app (and `davit compose`) log to stderr at a level set by the `DAVIT_LOG_LEVEL` env var (`trace`|`debug`|`info`|`notice`|`warning`|`error`|`critical`, default `info`); `compose --verbose` additionally bumps the process to `debug` unless `DAVIT_LOG_LEVEL` was explicitly (and validly) set.
- **Registries** — sign in to Docker Hub / ghcr.io / any registry to pull private images (Settings → Registries); credentials are verified against the registry and stored in the login keychain, shared with the `container` CLI. **Docker credential helpers** are honored too: if `~/.docker/config.json` has a `credHelpers`/`credsStore` entry for a registry (Google Artifact Registry via `gcloud`, ECR, etc.), Davit invokes the helper right before each pull and stages the short-lived token for the platform, so hourly-expiring credentials always work.
- **Menu bar extra** — service status, per-container quick actions from anywhere.
- **Auto-start containers** — mark any container "Start when Davit Opens" (context menu); on launch Davit brings the platform services up if needed and starts them. Combined with *Open at login*, your containers are running when you sit down.
- **Open at login** — optional launch-to-menu-bar at login (Settings → General), via `SMAppService`.
- **In-app updates** — checks GitHub Releases daily (or on demand from About); one click downloads the new version, verifies its Developer ID signature (team must match), swaps the bundle atomically with rollback, and relaunches. `Davit update check|install` headless.
- **Settings** — platform install-root override and refresh interval (General), plus a full **platform configuration editor** (Platform tab): default container CPUs/memory, registry, local DNS domain, builder resources/Rosetta, and advanced knobs (kernel, init image, machine). Only values differing from install defaults are written to `~/.config/container/config.toml`, `[plugin.*]` sections are preserved, every save is validated through the platform's own config loader before commit, and the result is published to the app root immediately — container defaults/registry/DNS apply to new operations right away, daemon-side settings after a service restart (button provided).

## Requirements

- Apple silicon Mac, macOS 15+ (macOS 26 recommended — matches `container` 1.1)
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

## Getting started

From a fresh install to something running in your browser:

1. **Open Davit.** On first launch, if Apple's container platform isn't installed, Davit downloads and installs it for you — no admin password needed.
2. **Pull a demo image** — Images → Pull Image → `nginxdemos/hello` (small, and it serves a visible page).
3. **Run it with a port** — Run the image, map host `8088` → container `80`.
4. **Open it** — the container's Ports row has *Open in Browser*, or visit `localhost:8088`. You'll see a page served from inside the container, showing its own hostname and IP.
5. **Explore** — live CPU/memory/disk, streaming logs, a one-click terminal, and Edit & Recreate to change ports/env/resources.

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
Davit exec <container-id> [command…]   # interactive TTY shell — or a one-off command — in a container (used by "Open Terminal")
Davit selftest                   # end-to-end test of the XPC service layer against the live daemon
Davit system start|stop          # bootstrap / tear down the container launchd services
Davit platform install|remove    # download + verify Apple's signed pkg into an app-managed install root
Davit registry login|list|logout # registry credentials (login reads the password from stdin)
Davit run [flags] IMAGE [COMMAND…]    # docker-style single-container run
    # flags precede IMAGE (docker convention; -- also ends flag parsing, --help prints usage and
    # exits 0): -d|--detach, --rm, --pull missing|always|never, -e/--env, --env-file, -t/--tty,
    # -u/--user, --uid, --gid, -w/--workdir, --ulimit, -c/--cpus, -m/--memory, --name, -p/--publish,
    # -v/--volume, --mount, --tmpfs, --network, --entrypoint, -l/--label, --platform, --arch, --os,
    # --cap-add, --cap-drop, --init, --read-only, --shm-size, --dns, --dns-search, --dns-option,
    # --no-dns, --rosetta, --virtualization, --ssh (forwards SSH_AUTH_SOCK from the host env),
    # --cidfile (written once the container is up; refuses to overwrite an existing file, docker
    # parity), --verbose|-q|--quiet. Clustered short flags (`-it`, `-dit`, …) are expanded the way
    # docker itself accepts them. Without -d, attaches to the new container's logs (no prefix,
    # status lines on stderr so stdout stays pure container output) until Ctrl-C, which detaches
    # only — the container keeps running (signals can't be forwarded to the guest process on this
    # platform, unlike docker) — and exits with the container's own exit code once it stops
    # (docker parity); with --rm, removal happens right after the attach ends rather than racing a
    # fast one-shot's daemon-side auto-remove, so output is never lost. -i/--interactive and docker
    # flags with no platform mapping (--restart, --privileged, --add-host, --hostname, --gpus, …)
    # are rejected outright rather than silently ignored.
Davit compose <subcommand> [-f <file>] [--env-file <path>] [--profile <p>]… [service…]
    # subcommands: plan | up [-d|--detach] | down [-v|--volumes] | ps | logs [-f|--follow] [--tail <n>]
    #              stop | start | restart | pull | exec <service> <command…>
    # file autodiscovered like docker; .env + ${VAR} interpolation; naming services scopes the
    # command (plan/up add the dependency closure; stop/start/restart/pull/ps/down take exactly
    # the named services). In-container service names resolve via managed /etc/hosts entries,
    # re-synced on every up/start/restart — recreates outside compose need another up/start.
Davit build -t <tag> <dir>       # build an image from <dir>/Dockerfile via the BuildKit shim
Davit machine list|create|boot|stop|delete   # container machines (micro VMs)
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
