# Roadmap — from HN feedback (Show HN, 82 pts)

Thread: https://news.ycombinator.com/item?id=48821848

Inventory of suggestions from the thread plus feature gaps vs. the two sibling
projects mentioned (contained-app, berth). Not commitments — a menu to prioritize.

## A. Direct suggestions from the thread

Status: **Wave 1 done** (shipped in `48a8a6a`, live on davit.app). The only
remaining A item is #2 (file browsing), intentionally scheduled in Wave 2.

| # | Suggestion | Who | Type | Status |
|---|---|---|---|---|
| 1 | Getting-started tutorial on the site: a good demo image; the run dialog's `nginx:latest` default is a weak demo | simonw | Docs/site | ✅ done — 2-min walkthrough on site + README, `nginxdemos/hello` demo, pull-sheet suggestion updated |
| 2 | In-container file browsing (list/download/upload/delete files inside a container) | neodymiumphish (also in contained-app) | Feature | ✅ done — Files tab (Wave 2) |
| 3 | State the memory footprint — "Docker Desktop is a memory hog, what's Davit's?" | ballislife30 | Docs | ✅ done — FAQ (architectural framing; platform idles ~25 MB) |
| 4 | Host→container name resolution / DNS | nvahalik; dofm suggests an Avahi/zeroconf alias trick | Docs (now) / feature (later) | ✅ doc done — FAQ documents the Avahi mDNS trick; built-in resolution still a later feature |
| 5 | OrbStack comparison + efficiency framing | oulipo2 | Docs/FAQ | ✅ done — FAQ |
| 6 | Menu bar integration | mrbnprck | — | ✅ already shipped |

## B. Feature gaps vs. contained-app / berth (context, not asks)

| Feature | Them | Us | Effort | Notes |
|---|---|---|---|---|
| Docker Compose import (parse compose → forms / multi-container run) | both | ✗ | L | apple/container has no native compose; we'd parse + create N containers |
| Registry login management (keychain creds) | both | ✗ | M | CLI had `registry login`; API likely exposes it — verify |
| "Reveal the `container` CLI command" before an action | contained-app | ✗ | S | Cheap trust/教学 win; we already build equivalent arg arrays |
| Global search across containers/images/volumes/networks | berth | partial (per-tab search) | M | |
| Image build from Dockerfile | contained-app (exp.) | ✗ | L | builder shim; heavier |
| Per-image tag/registry actions, Docker Hub search | contained-app | partial (tag only) | M | |
| File browsing | contained-app | ✗ | M | = item 2 |

## C. Proposed sequencing

**Wave 1 — quick, high-leverage (mostly docs) — ✅ DONE (`48a8a6a`, live):**
- (1) ✅ Getting-started section on davit.app + README using `nginxdemos/hello`.
- (5) ✅ OrbStack/Docker comparison + (3) ✅ memory FAQ (architectural framing).
- (4) ✅ Documented the Avahi alias trick for host→container name resolution.
- (6) ✅ Menu bar already shipped.

**Wave 2 — contained, high-value features:**
- (2) ✅ In-container **file browser** — Files tab: breadcrumb navigation, download
  (copyOut), upload (copyIn), delete; portable listing via `stat` with an `ls`
  fallback. Rows show clear folder/file affordances (chevron vs. download button).
  Backend covered by a selftest step. (shipped `a3e9902`)
- ✅ **"Reveal CLI command"** — the Run sheet shows the equivalent `container run …`
  command live as you fill the form, with copy. Teaches the CLI + builds trust
  (Davit runs over XPC, not the CLI, so this is the "here's what it maps to").

**Wave 2 is complete.** Next up is Wave 3 (registry login, Compose import, Dockerfile build) — demand-driven.

**Wave 3 — bigger bets:**
- ✅ Registry login management — Settings → Registries: add/list/remove logins, validated against the registry, stored in the login keychain (shared with the CLI). Headless: `Davit registry login|list|logout`.
- ✅ Docker Compose import — Containers → ⋯ → Import Compose File: parse → preview
  (services in depends_on order, volumes/networks, per-service CLI equivalents,
  honest warnings for unsupported keys) → create & start. Supported subset: image,
  container_name, environment (both forms), env_file, entrypoint, ports (incl.
  host-IP binds; non-tcp protocols warned), volumes (named/bind/tmpfs, ro),
  networks, cpus/mem_limit + deploy.resources.limits, command, user, working_dir,
  depends_on (incl. service_healthy / service_completed_successfully conditions),
  healthcheck, profiles, stop_grace_period/stop_signal, `.env` + `${VAR}`
  interpolation; in-container service-name resolution via managed /etc/hosts
  entries. `build:` not yet.
  Headless: `Davit compose plan|up|down|ps|logs|stop|start|restart|pull|exec` with
  docker-style file autodiscovery, service selection and profiles; parser and
  lifecycle covered by selftest steps.
- ✅ Image build from a Dockerfile — Images → Build Image: context/Dockerfile
  pickers, tag, build args, no-cache/re-pull toggles; drives the platform's
  BuildKit shim over vsock (auto-starting the builder), exports OCI, loads +
  unpacks + tags into the image store. Headless: `Davit build -t <tag> <dir>`.
  Known platform quirk: contexts under /tmp fail in the platform's file sync —
  Davit rejects them with a clear message. Compose `build:` support is now
  unblocked (future).

**Wave 4 — the thread's second round (shipped v0.1.9/v0.1.10):**
- ✅ Terminal picker (Settings -> General): Terminal/iTerm2/Ghostty/WezTerm/kitty/Alacritty/Warp.
- ✅ Settings fields typed "from the right" (trailing alignment) fixed.
- ✅ Site: dead Avahi gist replaced with the platform's real `container system dns`
  answer; de-AI copy pass; honest OrbStack perf FAQ.
- ✅ Auto-start containers ("Start when Davit Opens" + services bootstrap at launch).
- ✅ Images: Pull Latest (re-pull a tag to its newest digest).

**Wave 5 — GitHub issues (shipped v0.1.11):**
- ✅ #1 Machines: sidebar section, create/boot/stop/set-default/delete, detail view
  (overview, streamed logs, live stats via the backing container, inspect),
  one-click Terminal (machine login shell), edit cpus/memory/home-mount.
  Headless: `Davit machine list|create|boot|stop|delete|exec|set`.
- ✅ #2 Homebrew install roots (/opt/homebrew/opt/container + Intel prefix).
- ✅ #7 Docker credential helpers: per-pull resolution from ~/.docker/config.json
  (gcloud/ECR-style), staged into the keychain the pull daemon reads; covers
  pulls, run auto-pull, compose, machine create. Build-time base images still
  resolve in the shim (future).
- ✅ #4/#5/#6 answered + FAQ ("replace Docker Desktop?", local images, compose).
- Later: machine `.machine` DNS assumed default domain; devcontainers idea (#6);
  compose `build:`; ~~1.1.0 platform bump~~ (done, v0.1.12). ClientProcess.kill
  bug confirmed upstream on apple/container#1941 (2026-07-13, our findings added);
  when it's fixed, the compose healthcheck abandoned-probe workaround can become
  a real kill.

## Feasibility notes (grounded in the API)
- File browsing: `ContainerClient.exec` + `copyIn`/`copyOut` exist — no new daemon capability needed.
- Registry login: the platform had `container registry login`; confirm the client surface before scoping.
- Compose/build: larger; build needs the builder shim, compose is pure app-side orchestration.
