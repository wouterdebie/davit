# Compose parity extensions — plan

> Source of truth for extending main's shipped compose (Compose.swift) toward
> docker-compose parity. Execute E1…E5 top-to-bottom; verification = `swift build`
> + full `Davit selftest` (live daemon, this machine is macOS 26) before each commit.
> Line numbers verified 2026-07-08 on `feature/compose-parity` (== main @ ffbba35).

**Goal:** `Davit compose up` with compose-file autodiscovery, docker-style service
selection (`Davit compose up db alloy` = named services + dependency closure),
`profiles`, `healthcheck`, and honored `depends_on` conditions
(`service_started` / `service_healthy` / `service_completed_successfully`).

**Approach:** extend the existing architecture in place — `Compose.parse` → `Plan` →
`Compose.up` (Compose.swift), CLI dispatch in Main.swift:172-205, ComposeImportSheet.
No new files unless a type clearly outgrows Compose.swift. Match the maintainer's
minimal style (manual arg loops, warnings list, Error enum, sequential up).

## Verified findings (cites into current checkout)

- Parse: `Compose.parse(text:projectName:baseDir:)` → `Plan{project, volumes, networks,
  services:[ServicePlan], warnings}`; ServicePlan carries the 4 flag arrays + cliPreview
  (Compose.swift:11-38,60). Handled service keys listed at :236-239; everything else →
  "not supported — ignored" warning (:240-242). depends_on: list or map, map conditions
  DISCARDED with warning (:224-233); deps feed Kahn topoSort (:267-284) only.
- Up: `Compose.up(plan:progress:)` (:327-369) — create missing volumes/networks, then
  sequential `runContainer` per service in topo order; no waiting, no labels, no
  recreate (name collision throws), stops at first failure.
- Exec primitive: `ContainerService.exec(_ id:_ argv:) -> ExecResult{stdout,stderr,
  exitCode}` (FileSystem.swift:23-59) — NO timeout (process.wait() blocks). Upstream
  1.0.0 bug: `ClientProcess.kill` encodes signal as Int64, apiserver expects string
  (checkout ClientProcess.swift:79-83) and ContainerXPC is not linked → a timed-out
  probe cannot be killed; it must be abandoned (counts as failure; process exits on its
  own or at container stop). Document, don't fight it.
- Exit codes: only source is the bootstrap `ClientProcess` from `client.bootstrap`,
  currently dropped in `start()` (Backend.swift:194-208). Snapshots carry no exit code.
- CLI: `compose plan|up <file>`, no flags; semaphore + Task.detached + exit() pattern
  (Main.swift:172-205). `build` mode has the manual flag-loop pattern to copy
  (Main.swift:140-155).
- GUI: ComposeImportSheet keyed on `Compose.StepKind` set (ComposeImport.swift:14-19,
  101-110); `--pose-compose` harness hook (Containers.swift:83-97).
- Selftest: pure parse step "compose: parse subset + ordering + cycle rejection"
  (Main.swift:430-482); `runBlocking` is semaphore-based (Main.swift:291-298) — fine
  here because compose progress closures are @Sendable, not @MainActor.

## Design decisions (docker-compose parity semantics)

1. **Autodiscovery** (when no `-f`/positional file): try, in order, `compose.yaml`,
   `compose.yml`, `docker-compose.yml`, `docker-compose.yaml` in cwd, then walk parent
   directories (docker behavior). `COMPOSE_FILE` env (single path) takes precedence.
   Warn when both `compose.yaml` and `compose.yml` exist in the winning directory.
   Project name = winning file's directory basename (unchanged convention).
2. **CLI syntax** (backward compatible):
   `Davit compose plan|up [-f|--file <path>] [--profile <name>]... [service...]`.
   A positional arg counts as the file (old syntax) iff no `-f` given AND it looks like
   a path (contains `/` or ends in `.yml`/`.yaml`); path-like but missing → error
   `compose file not found: X` (exit 1). Otherwise it's a service name; unknown service
   → error `no such service: X` (exit 1). Usage (incl. flag typos) → exit 2.
3. **Service selection:** selected = named services + transitive `depends_on` closure,
   kept in topo order; created volumes/networks pruned to those the selected services
   reference. Applies to both `plan` and `up`, and is available to the GUI as API.
4. **Profiles:** active set = repeated `--profile`; comma-separated `COMPOSE_PROFILES`
   is the fallback when no flags are given (docker v2). `"*"` activates every profile.
   Services without `profiles:` are always enabled. Explicitly-named CLI services
   auto-activate their own profiles (docker v2). A dependency pulled in by closure that
   remains profile-disabled → error naming the missing profile (close to docker; we
   choose the explicit error over silent inclusion). Profile-excluded services drop out
   of Plan.services entirely (and out of volume/network pruning).
5. **healthcheck:** parse `test` (string → CMD-SHELL; array with CMD / CMD-SHELL head;
   `NONE`), `disable: true`, Go-style durations (`300ms`, `5s`, `1m30s`) for
   `interval`/`timeout`/`start_period`, `retries`. Docker defaults: interval 30s,
   timeout 30s, retries 3, start_period 0. Probe = `ContainerService.exec` with a
   timeout race (`withThrowingTaskGroup`: wait vs `Task.sleep`); timeout counts as a
   failed probe, the probe process is abandoned (see findings). Healthy after one
   successful probe; unhealthy after `retries` consecutive failures counted only after
   `start_period` has elapsed (failures inside start_period don't count; a success
   inside it does).
6. **depends_on conditions:** map form now honored. Before starting a dependent:
   `service_started` = current behavior (dep's runContainer returned);
   `service_healthy` = wait for the dep's healthcheck to report healthy (dep without a
   healthcheck → parse/plan-time error, docker parity);
   `service_completed_successfully` = wait for dep's exit code == 0 via a new opt-in
   exit-code registry (dep started in this same `up`; nonzero → error `service X didn't
   complete successfully: exit N`). Progress surface: new
   `StepKind.waiting(service: String, condition: String)` case; GUI shows it as the
   running caption, CLI prints `up: waiting for <svc> (<condition>) done`.
7. **Exit codes:** `runContainer(..., retainExitCode: Bool = false)` threads to
   `start(_ id:retainExitCode:)`; when set, the bootstrap `ClientProcess` is handed to a
   small `actor` registry (`ComposeExitCodes`: register spawns a Task awaiting
   `process.wait()`, `exitCode(for:)` awaits it). Compose.up passes `true` only for
   services that something depends on with `service_completed_successfully`.
8. **GUI:** minimal — sheet handles the new StepKind (caption; excluded from the
   checkmark grid or shown transiently), and profile-gated services surface as an info
   warning ("service X requires profile Y — activate via CLI --profile"). No profile
   picker in v1.

Out of scope (unchanged from main): `down`/`ps`, labels, restart policies, network
aliases, `env_file:` key, `build:` inside compose. Candidates for a follow-up; do not
creep. (`.env` + `${VAR}` interpolation and host-IP port binding were promoted to
follow-up tasks F1/F2 below on user request, 2026-07-09.)

9. **.env + interpolation (F2):** default env file = `<composeDir>/.env` (docker
   project-directory behavior), overridable via a new `--env-file <path>` CLI flag
   (tilde-expanded, relative to cwd; missing explicit file → error, missing default →
   silently absent). Effective env = process environment ∪ .env, process wins (docker
   precedence). Interpolation applies to every string VALUE in the loaded YAML tree
   (never keys), after Yams.load, before the existing per-key parsing: `${VAR}`,
   `${VAR:-def}`, `${VAR-def}` (':' variants treat set-but-empty as unset),
   `${VAR:?err}`/`${VAR?err}` → Compose.Error with the message, bare `$VAR`, `$$` →
   literal `$`; unset plain substitution → empty string + warning (docker parity).
   Single-level only (no nested defaults) — documented. Bare `KEY` entries in
   environment list form resolve from the effective env; unset → omitted + warning.
   GUI import loads the sibling `.env` automatically via the same helper.
10. **Host-IP publish (F1):** short form `IP:host:container[/proto]` and long form
   `host_ip` pass through as `--publish ip:host:container[/proto]` (Apple's Flags
   accept it; Parser.swift:606-718 in the checkout validates incl. bracketed IPv6).
   Remove the drop-warning; keep the tcp-only-protocol warning. Ports <1024 still fail
   at runtime in the user launchd session — unchanged platform limit.

## Tasks

- [ ] **F1 — Host-IP port binding.** Implement decision 10 in Compose.swift ports
  parsing (short 3-part + long-form `host_ip`); update the pure selftest assertions
  that currently expect the host IP to be dropped (Main.swift compose parse step) to
  expect passthrough. Done when: build + full selftest OK. Commit:
  `compose: publish host-IP bindings`.
- [ ] **F2 — .env + ${VAR} interpolation.** Implement decision 9: dotenv parser
  (KEY=VALUE, `#` comments, blank lines, optional `export `, single/double-quote
  stripping), `Compose.effectiveEnvironment(composeDir:envFile:)` helper, interpolation
  pass, bare-KEY resolution, `--env-file` flag + usage update, GUI wiring, README
  mention. New pure selftest step covering: ${VAR} from .env, process-env precedence,
  both default forms, `:?` error, `$$` escape, bare $VAR, unset→empty+warning, bare KEY
  list entry resolution + omission warning, --env-file override. Done when: build +
  full selftest OK + CLI round-trip with a temp .env. Commit:
  `compose: .env files + variable interpolation`.

- [x] **E1 — Parse layer (Compose.swift + selftest).** ServicePlan gains `profiles:
  [String]`, `healthcheck: Healthcheck?`, `dependsOn: [String: DependsCondition]`
  (list form → .started). New `Compose.Healthcheck` struct + Go-duration parser; new
  `DependsCondition` enum (started/healthy/completedSuccessfully; unknown condition
  string → warning + .started). Remove the "conditions are ignored" warning; add
  plan-time validation: healthy-condition dep without healthcheck → new
  `Error.missingHealthcheck(service:dependency:)`. Parse `profiles` (list of strings).
  New selection API: `Plan.selecting(services: [String], activeProfiles: [String])
  throws -> Plan` implementing decisions 3+4 (closure, topo-subset, volume/network
  pruning, profile activation/errors: `Error.noSuchService`, `Error.inactiveProfile`).
  Keep `parse` signature compatible (selection is a separate step). Extend the existing
  pure selftest step (or add "compose: selection + profiles + healthcheck parse"):
  assert condition parsing, healthcheck defaults + duration parsing + CMD forms,
  profile filtering incl. auto-activation rule, closure selection + pruning,
  noSuchService + missingHealthcheck + inactiveProfile errors. Done when: build +
  full selftest OK. Commit: `compose: parse profiles, healthchecks, depends_on conditions + service selection`.
- [x] **E2 — Backend exit codes + probe timeout.** `start(_ id:retainExitCode:)` +
  `runContainer(retainExitCode:)` (defaulted, existing callers untouched) registering
  the bootstrap handle in `actor ComposeExitCodes` (lives in Compose.swift; static
  shared; register + exitCode(for:) with await). `ContainerService.exec` gains
  `timeout: Duration? = nil` (race; on timeout throw a typed error; document abandoned
  probe). Done when: build + full selftest OK (live suite exercises start via existing
  steps). Commit: `compose: exit-code retention + exec timeout`.
- [x] **E3 — Conditions in up (Compose.swift + ComposeImport.swift + selftest).**
  Healthcheck prober (decision 5) + condition waits before each dependent service
  (decision 6) + `StepKind.waiting` + GUI handling + CLI progress line (the Main.swift
  print already prints any StepKind — verify formatting). Compose.up sets
  retainExitCode for completed_successfully deps. New live selftest step "compose: up
  with depends_on conditions": fixture project `davit-selftest-compose` — `db` alpine
  `sleep 300` + healthcheck `["CMD-SHELL","test -f /ready"]` interval 1s retries 20;
  `init` alpine `["true"]`; `web` alpine `sleep 300` depends_on db:service_healthy +
  init:service_completed_successfully. Run up in a child Task; poll for db running,
  exec `touch /ready`; assert up completes, web running, progress contained waiting
  steps for both conditions. Failure path: mini-fixture w/ healthcheck `["CMD","false"]`
  retries 2 interval 1s → up throws. defer: force-delete all fixture containers +
  volumes. Done when: build + full selftest OK. Commit: `compose: honor depends_on conditions with healthchecks`.
- [x] **E4 — CLI: autodiscovery + selection + profiles (Main.swift + README).**
  Rewrite compose dispatch per decisions 1+2 (manual flag loop in build-mode style;
  usage string `usage: compose plan|up [-f <file>] [--profile <name>]... [service...]`).
  Autodiscovery helper in Compose.swift (`Compose.discoverFile(from cwd:) -> String?` +
  env override) so it's selftest-testable; pure selftest step "compose: file
  autodiscovery" using temp dirs (nested dir finds parent's compose.yaml; docker-compose
  fallback order; COMPOSE_FILE override; both-yaml warning). README: update the compose
  feature bullet + Binary modes line to the new syntax. Done when: build + full
  selftest OK + verifier runs a real `plan`-mode round-trip from a temp dir (no `-f`,
  autodiscovered; with service selection + `--profile`) asserting output. Commit:
  `compose: CLI autodiscovery, service selection, profiles`.
- [x] **E5 — Review + wrap.** Code-review agent over the E1–E4 diff (correctness,
  docker-semantics fidelity, style match); fix findings; final full build + selftest +
  headless plan round-trip evidence. Commit: `compose: review fixes` (or fold).

## Risks / notes

- Timed-out probes leak until the probed command exits (kill bug, see findings) — doc'd
  in code; default timeout 30s matches docker so well-formed healthchecks are unaffected.
- `service_completed_successfully` only works for deps started in the same `up`
  invocation (registry is in-process; snapshots have no exit codes) — matches how the
  feature is used in practice; error message explains the limitation otherwise.
- Profile-gated dependency semantics chosen as explicit error (see decision 4) — slight
  divergence from docker's auto-activation edge cases; revisit if users hit it.
- The GUI sheet keys progress off StepKind equality — the new `.waiting` case must be
  Hashable-safe with associated values (it is, synthesized) and not break the
  checkmark grid keyed on volume/network/service cases.
