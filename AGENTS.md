# AGENTS.md

Shared guidance for coding agents working in this repository.

> **Placeholders, not values.** `<YOUR_TEAM_ID>`, `<your-server>`, `<deploy-dir>` and
> `*.example.com` stand in for your own. Nothing identifying is committed: the team id comes from
> `DEVELOPMENT_TEAM` (see `native/.env-local.example`), and secrets live on your server. The author's
> own hosts and paths are in `DEPLOYMENT.local.md`, which is gitignored — as is anything matching
> `*.local.md`. **This repo is public. Keep it that way.**

## What this is

An **iOS and macOS** app to control and monitor a Chinese-market Bambu Lab printer — currently an
**H2C** (dual-nozzle, 9 addressable AMS trays). The official Bambu Handy app can't drive these
units. It is a polished client of a **self-hosted Bambuddy backend** (FastAPI, ~548 endpoints).

**Distribution is TestFlight, to real testers.** This is not a single-user sideload, and the
difference matters: it rules out shortcuts the rest of this repo has deliberately not taken.
`canopy/` exists so **users need no Apple account of their own**; Trellis is "the service each USER
runs next to their own Bambuddy"; and there is a documented case for someone running a build signed
by **another team**, who cannot get push at all and for whom switching it off is correct. Treat
copy, empty states, failure messages and capability gating as things a stranger will read without
being able to ask what they meant.

PR CI runs the macOS native suite, applicable service suites and guidance checks; iOS/device and release checks remain local through Xcode. Trellis also has its existing image/release workflow.

Monorepo layout:

- `native/` — **the app.** SwiftUI, iOS + macOS, one target. All new work lands here.
- `deploy/` — docker-compose for the Bambuddy backend + Bambu Studio / OrcaSlicer sidecars.
- `deploy/trellis/` — the push + MakerWorld service each USER runs next to their own Bambuddy.
- `canopy/` — the APNs relay the app AUTHOR hosts (Go). Holds the signing keys so users need no
  Apple account, verifies App Attest, binds each push token to one tenant.
- `docs/native-rewrite/` — reference for things that are **not** the app's own code: the backend's
  API surface, MakerWorld's measured behaviour, the printer's firmware refusals, the camera's frame
  rate, the Mac architecture.
- `docs/phase0-results.md` — validated backend facts (URLs, auth, preset names). No secrets.
- `archive/` — the retired Expo app (`archive/mobile/`) and the port specification
  (`archive/docs/`). **Not maintained.** Read `archive/README.md` before assuming anything there is
  current; several of its decisions are still load-bearing and that file says which.

## Commands

Run from the repository root. Read the corresponding [reference section](AGENT-REFERENCE.md) before native builds, releases or deployments.

```bash
(cd native && xcodegen generate)
# Native destinations, Xcode selection, release and device recipes: reference, The app / Shipping.
./native/scripts-lint.sh
(cd canopy && go build ./... && go vet ./... && go test ./...)
./deploy/trellis/scripts-test.sh
(cd deploy/stl-texturize && npm test)
```

The native source is `native/project.yml`; never commit or hand-edit the generated Xcode project. Swift 6 strict concurrency is enabled. Test both iOS and macOS after shared native changes; use the reference's Xcode commands and count actually discovered tests. Never substitute tests in the retired Expo archive.

## Rules that matter throughout

- This is a public repo and an app distributed to real testers. No identifying deployment configuration, signing material, captured private attestation fixtures or credentials in tracked files. Keep `*.local.md` private.
- Read the actual backend handler and callers before changing capability predicates or request parameters. Gate an affordance on the exact capability it needs and explain unavailable capabilities in the UI. Verify the control is actually wired.
- The app never holds a Bambu Cloud bearer. Anonymous search stays anonymous; owner collections use Trellis. Collections must not depend on the push toggle (`laPushUrl` and `resolvePushUrl` answer different questions).
- Live Activity ContentState field names are a wire contract shared with Trellis. App Attest claims use `ClaimSequencer` for challenge → proof → POST as one ordered unit; a refused claim must not erase a known card/binding.
- `ams_mapping` is indexed by file filament slot, valued by global tray ID. Query filament requirements for the exact file/plate; do not infer nozzle selection from an unsupported create field.
- iOS/macOS share model and business logic; only views fork. Use AppModel stores, clear cross-session state on attach, and use the existing scene/inspector rules. Read the Mac reference before window, menu-bar or inspector changes.
- Read local Apple HIG/SDK references before platform UI changes. Live Activity render tests do not prove device lifecycle/APNs behaviour; device verification remains required for those paths.
- Use the existing release/deployment scripts. Never invent rsync flags over live data, upload with a beta Xcode, or assume an archive succeeded from log text alone. Only bump CURRENT_PROJECT_VERSION; preserve the marketing version unless explicitly requested.

## Read for the task

Read the matching sections of [AGENT-REFERENCE.md](AGENT-REFERENCE.md) before changing or reviewing these areas:

| Area | Sections |
| --- | --- |
| Native build/toolchain/SwiftUI | The app; Linting; Apple platform rules |
| macOS scenes, appearance, inspectors, probes | native is TWO destinations (including Debug identity and probe limits) |
| Search/import/collections | MakerWorld; laPushUrl vs resolvePushUrl; Bambuddy auth quirks |
| Filament and slicing | Printing more than one filament |
| Push, claims, Live Activities | The push relay; Apple platform rules; The recurring bug |
| Thumbnails, plate identity, capabilities | The recurring bug; Bambuddy auth quirks |
| Distribution/deployment | Shipping; Releasing Trellis |
| Test selection and dependency skips | Testing |

The history stays there rather than accumulating in this always-loaded guide. Update the relevant reference when changing one of its contracts.

## Completion and review

Use authorized routine execution; the personal `interactive-engineering-review` skill is opt-in. Finish a coherent change, run relevant checks, inspect the diff and commit explicit paths. Keep unrelated work intact.

PR CI checks guidance on every PR and runs Canopy/STL-texturize suites plus macOS native tests when their paths or the CI workflow change. The existing Trellis workflow tests and builds Trellis when it changes. These do not prove iOS device or deployment readiness; run and report those checks when applicable.

Before a requested merge, verify applicable CI on the final PR commit after all fixes. Missing tools, zero tests, unexpected skips, timeouts and unfinished reviews are incomplete verification. Record what actually ran and any remaining coverage gap; verify the merge/deployment result before reporting it complete.

## Code Review Rules

Read the applicable reference sections; report concrete introduced failures with their trigger and affected lines, including security, compatibility and documentation drift. CI handles mechanical checks. A completed AI review without serious findings does not establish that lower-priority docs or on-device behaviour were verified.

## Shared guidance

`AGENTS.md` is maintained; `CLAUDE.md` imports it. Keep each instruction chain within the tracked 32 KiB budget. Client credentials, permissions and runtime hooks remain separate local configuration.
