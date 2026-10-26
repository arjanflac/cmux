# Maintained quiet Codex frontend for cmux+

This directory pins Codex 0.164.0 and maintains a small derived TUI for cmux+.
It is opt-in presentation code, with an ongoing patch and compatibility cost.
The stock `codex` installation and shared daemon remain the owners of execution.
Do not compile Rust on the 8 GB workstation or replace its ordinary CLI.

`Quiet Codex rendering proof` applies the synthetic tests to stock, requires an
executed behavioral failure, then applies the rendering patch and reruns them.
The recorded 0.164.0 proof passed seven patched rendering tests. The separate
frontend build applies the attach boundary, tests it and produces an arm64 macOS
artifact. These new native/Rust boundaries still need a successful build and
live compatibility checks before installation or enabling the setting.

The rendering cohort covers agent shell commands, text-only MCP and dynamic tool
calls. Compact fullscreen presentation shows the tool name and truthful status.
Original transcript cells, search and F4 details remain. Unknown items,
user-shell commands, approvals/questions and media keep their existing paths.

## Build and include in a candidate

Dispatch the existing proof workflow on the exact reviewed source branch:

```sh
gh workflow run quiet-codex-proof.yml --repo arjanflac/cmux \
  --ref feat/cmux-session-setup -f build_frontend=true
```

The release tag's local lockfile version labels need normalization; `check.py`
checks that every external dependency/revision/checksum stays unchanged before
using `--locked`. Build/test logs, upstream license and patch/binary hashes ship
with the artifact. No model request or live daemon is used by that build.

A successful frontend run can be selected through `quiet_frontend_run` in the
personal app workflow. Alternatively, download that exact run's ARM64 artifact
and pass `--quiet-artifact <directory>` to the existing `personal-package.py`
candidate packaging command. Packaging checks the source pin, all three patch
hashes, executable checksum, architecture and signature before copying it beside
the wrapper and signing the candidate. Packaging without the argument omits the
derived frontend. Follow the normal runbook's safe install window; never replace
or restart an occupied app to try this feature.

## Launch and maintenance contract

`terminal.codexQuietFrontend` defaults off. It controls future cmux terminals;
type normal `codex`. The per-terminal wrapper supports plain interactive launch,
`resume` and an explicit resume UUID, with a narrow set of model, cwd, sandbox
and approval flags. Other flags, prompts and noninteractive commands use stock
before submission. The frontend requires the same CLI and daemon version and a
verified local daemon socket. It preserves local workspace configuration and
cwd, using stock helper paths instead of invoking itself as a harness helper.

Embedded backend startup, daemon auto-start, restart/update recovery, daemon
maintenance, managed-worktree startup and self-update are blocked in this build.
Failure after frontend exec exits that frontend; it never replays input or
falls back to stock after uncertain acceptance. No output filtering, global
hooks, launcher/profile replacement or extra perpetual service is involved.

Updating stock Codex can make this lane fall back to stock until the source pin,
patches and tests are maintained and a new frontend is bundled. A repatch/update
button is not implemented. Phone steering, native computer use, restoration and
resource use must still be checked with the real built frontend, without
restarting the stock daemon or resubmitting active work.

Prompted by [Codex issue 18396](https://github.com/openai/codex/issues/18396) and
[WladmirJunior's focus prototype](https://github.com/WladmirJunior/codex/commit/18208da18be401804c4ae48ea6533193d56371b3).
The implementation does not copy its global configuration, model instructions,
commentary suppression or failed-command hiding policy.
