# Compose improvements — plan (user-feedback round)

> Source of truth for four user-reported improvements. Branch
> `feature/compose-improvements` off `main` @ d7babbf (post PR #9 merge; platform
> pins now container 1.1.0 / containerization 0.35.0; maintainer added compose-network
> DNS `e135f66` and ownership labels `232b087` — read the CURRENT code, some
> pre-merge assumptions no longer hold). Execute I1…I5 top-to-bottom; verification =
> `swift build` + full `.build/debug/ContainerStack selftest` (live daemon, macOS 26)
> + the named CLI round-trips, before each commit.

## User decisions (fixed)

1. `.env` interpolation: **docker parity** — values interpolated at load time;
   single-quoted values stay literal.
2. Default memory: **Settings only** — no new compose code; document it.
3. Failure handling: **opt-in flag** `--down-on-failure`; default stays docker-parity
   (leave started services running).
4. Log level: **both** — compose `--verbose`/`--quiet` flags AND app-wide
   `DAVIT_LOG_LEVEL` env var wiring swift-log.

## Verified findings (2026-07-09, cites into main)

- **Default memory already works via Settings**: `Backend.runContainer` always passes
  `Backend.systemConfig()` into `Utility.containerConfigFromFlags`; `Parser.resources`
  (checkout Client/Parser.swift:105-124) seeds cpus/memory from
  `containerSystemConfig.container.{cpus,memory}` and only overrides when the service
  sets `cpus`/`mem_limit`/`deploy.resources.limits` (Compose.swift:547-553). The 4-CPU /
  1 GiB numbers are library fallbacks used only when config.toml has no `[container]`
  table; Settings → Platform writes that table (SettingsView.swift:217-218,270-276) and
  publishes it to the app root (Backend.swift:939). → I2 is docs-only.
- **Dotenv**: `parseDotEnv(text:)` Compose.swift:168 strips one matching pair of
  single OR double quotes without recording which; NO load-time interpolation
  (env_file comment at :392-399 calls the literal behavior a deliberate deviation —
  now being reversed by user decision 1). The substitution machinery to reuse:
  `substitute(_:environment:warned:warnings:)` Compose.swift:228-291 (grammar: `$VAR`,
  `${VAR}`, `${VAR:-def}`, `${VAR-def}`, `${VAR:?err}`, `${VAR?err}`, `$$`; single-pass).
- **Logging**: exactly one `Logger` exists — `Backend.log` (Backend.swift:95, label
  "dev.wouter.davit"), passed only to `containerConfigFromFlags` (Backend.swift:286).
  `LoggingSystem.bootstrap` is never called (default = stderr @ .info). Correct wiring
  point: `ContainerBinary.bootstrapEnvironment()` (Backend.swift:50-54), which
  `Main.main()` runs first.

## Design

**I1 — .env / env_file load-time interpolation (docker semantics).**
`parseDotEnv` becomes quote-aware: track per-value whether it was single-quoted.
After parsing each line, non-single-quoted values are interpolated immediately with
the existing `substitute` grammar against lookup = process environment (wins) ∪
previously-defined entries of the same file (left-to-right self-reference). Errors
(`${X:?msg}`) throw as usual; warnings flow into the existing warnings channel where
available (effectiveEnvironment/env_file call sites) — `parseDotEnv` returns the
warnings rather than printing. Applies to BOTH the project `.env`
(`effectiveEnvironment`) and `env_file:` entries (Compose.swift:433) — update the
now-stale comment at :392-399. NO recursive expansion at YAML-substitution time
(unchanged). User's case `VARIABLE_1="${HOME}/test"` (double-quoted or unquoted)
resolves at load; `'${HOME}/test'` (single-quoted) stays literal by design.

**I2 — default memory documentation.** README: one- or two-sentence note in the
compose section: services without `mem_limit`/`cpus` use the platform defaults, which
are changed in Settings → Platform (default container CPUs/memory) — each service is
a lightweight VM, so the default is reserved per container. No code.

**I3 — `compose up --down-on-failure`.** New bool flag (up only). Semantics: track
what THIS up invocation touched (services started/created, networks/volumes it
created); on any thrown error mid-up: print `up failed — tearing down (--down-on-failure)`,
best-effort `Compose.down` scoped to the selected services (removeVolumes: false;
networks per existing full/partial down rules — partial teardown when the up was
service-scoped), then rethrow the ORIGINAL error (exit 1; teardown warnings printed,
teardown failure noted but never masks the original error). Default without the flag:
unchanged. Usage string + README updated (I5 owns final docs pass).

**I4 — log levels.**
(a) App-wide: in `ContainerBinary.bootstrapEnvironment()`, `LoggingSystem.bootstrap`
with a `StreamLogHandler.standardError` whose level comes from `DAVIT_LOG_LEVEL`
(trace|debug|info|notice|warning|error|critical, case-insensitive; unset → .info;
invalid → .info + one stderr warning). Bootstrap exactly once, before any library call.
(b) Compose CLI: global `--verbose`/`-q|--quiet` flags on all compose subcommands
(mutually exclusive → usage error). Verbose: print diagnostics currently silent —
resolved compose file path always, effective project name, per-service equivalent
`container run` line during up (plan already prints them; up echoes on verbose),
hosts-sync/DNS actions, health-probe attempts+results, pull stages, down per-resource
detail. Quiet: suppress warnings and progress lines; errors only. Implementation:
a small `ComposeOutput` (level enum quiet/normal/verbose + print helpers) threaded
through the CLI paths — keep GUI behavior untouched. Verbose also sets the swift-log
level to .debug for the process unless DAVIT_LOG_LEVEL was explicitly set.

## Tasks (implementers: sonnet, strong briefs; verifiers: sonnet, evidence-first)

- [x] **I1 — dotenv load-time interpolation.** Per Design I1. Pure selftest
  extensions: user's exact scenario (`.env` containing `V="${HOME}/test"` → compose
  `${V}` yields expanded HOME path; single-quoted variant stays literal), left-to-right
  self-reference (`A=1`, `B=${A}2` → `B=12`), process-env-wins lookup, `${X:?}` error
  from a .env value, env_file: values now interpolated (update its selftest + stale
  comment). Done when: build + full selftest OK. Commit:
  `compose: interpolate .env and env_file values at load (docker parity)`.
- [x] **I2 — default-memory docs.** Per Design I2, README only. Done when: build OK
  (no code change) + README renders sensibly. Commit:
  `compose: document platform default memory/cpus for services without limits`.
- [x] **I3 — --down-on-failure.** Per Design I3. Live selftest: fixture svc a
  (alpine sleep 600) + svc b (nonexistent image tag) — up WITHOUT flag → a's container
  remains (then clean); up WITH flag → error surfaced AND no project containers remain.
  CLI round-trip of the same. Done when: build + full selftest OK + round-trip.
  Commit: `compose: opt-in full teardown on up failure (--down-on-failure)`.
- [x] **I4 — log levels.** Per Design I4. Pure selftest: level-string parsing.
  CLI round-trips (verifier): `DAVIT_LOG_LEVEL=debug compose plan` runs (no crash,
  bootstrap once); `compose up -d --verbose` prints diagnostics incl. equivalent
  command lines; `--quiet` prints nothing but errors on a warning-producing fixture;
  `--verbose --quiet` → usage exit 2. Done when: build + full selftest OK +
  round-trips. Commit: `compose: --verbose/--quiet + DAVIT_LOG_LEVEL`.
- [x] **I5 — review + wrap.** Single correctness/parity reviewer over the I-round
  diff (adversarially verified findings), fixer, docs/usage final pass, full suite +
  smoke round-trip, commit `compose: improvements round review fixes + docs`.

## Notes / risks

- Platform 1.1.0 bump landed on main — if the local daemon/selftest misbehaves for
  platform reasons unrelated to this round, verifiers must report evidence, not
  work around silently.
- Maintainer's compose-network DNS (`e135f66`) may have changed/removed hosts-sync
  internals — I3/I4 touch up/down paths: read the current implementation first.
- `--quiet` must not swallow the final error line (exit-code consumers still need
  stderr text).
