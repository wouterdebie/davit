# Roadmap — from HN feedback (Show HN, 82 pts)

Thread: https://news.ycombinator.com/item?id=48821848

Inventory of suggestions from the thread plus feature gaps vs. the two sibling
projects mentioned (contained-app, berth). Not commitments — a menu to prioritize.

## A. Direct suggestions from the thread

| # | Suggestion | Who | Type | Effort | Impact |
|---|---|---|---|---|---|
| 1 | Getting-started tutorial on the site: a good demo image, screenshots or a silent video of getting it running; the run dialog's `nginx:latest` default is a weak demo | simonw | Docs/site | S | High |
| 2 | In-container file browsing (list/download/upload files inside a container) | neodymiumphish (also in contained-app) | Feature | M | High |
| 3 | State the memory footprint — "Docker Desktop is a memory hog, what's Davit's?" | ballislife30 | Docs (+ maybe a live stat) | S | Med |
| 4 | Host→container name resolution / DNS (reach a container by name from the host) | nvahalik; dofm suggests an Avahi/zeroconf alias trick | Feature or docs | S (doc) / L (build) | Med |
| 5 | OrbStack comparison + efficiency framing | oulipo2 | Docs/FAQ | S | Med |
| 6 | Menu bar integration | mrbnprck | — already shipped | — | — |

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

**Wave 1 — quick, high-leverage (mostly docs, ~an afternoon):**
- (1) Getting-started section on davit.app + README: pick a demo image that *does something visible*
  (e.g. a web app you open in the browser), with the existing screenshots.
- (5) OrbStack/Docker Desktop comparison + (3) memory footprint, as a short FAQ on the site.
  Measure Davit's real idle/active RSS to quote a number.
- (4, doc form) Document the Avahi alias trick for host→container name resolution.
- (6) Nothing to build; maybe make the menu bar more discoverable in docs.

**Wave 2 — contained, high-value features:**
- (2) In-container **file browser**: feasible today via `exec` (ls/stat) + `copyIn`/`copyOut`
  (both already on ContainerClient). A new detail tab: browse tree, download/upload, delete.
- "Reveal CLI command" affordance on run/exec/etc. — small, builds trust.

**Wave 3 — bigger bets (pick based on demand):**
- Registry login management (unblocks private images cleanly).
- Docker Compose import (most-requested class of feature in this space).
- Image build from a Dockerfile.

## Feasibility notes (grounded in the API)
- File browsing: `ContainerClient.exec` + `copyIn`/`copyOut` exist — no new daemon capability needed.
- Registry login: the platform had `container registry login`; confirm the client surface before scoping.
- Compose/build: larger; build needs the builder shim, compose is pure app-side orchestration.
