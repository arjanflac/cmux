# cmux quiet Codex frontend

This is a maintained, cmux-bundled derivative of the pinned Codex TUI. It attaches
to the existing stock managed daemon. The ordinary `codex` executable, official
apps, global configuration and phone access are unchanged.

`terminal.codexQuietFrontend` defaults off. Enable **Hide Codex Tool Calls** in
Terminal settings, open a new cmux terminal, and run normal `codex`. Positively
identified routine agent command calls (including terminal polling), text MCP
calls and dynamic text tool calls occupy no transcript rows. **Ctrl+T** switches
between true quiet and the original compact view. Assistant messages, user shell
commands, failures, approvals, unknown/media content and meaningful status stay
visible. Full-content search and F4 retain the original tool data.

## Launch boundaries

Plain interactive launch, `resume` and an explicit resume UUID are supported,
with a narrow set of model, cwd, sandbox and approval flags. Other flags, prompts
and noninteractive commands use stock before input or thread submission. The
frontend requires matching stock CLI/daemon versions and a verified local daemon
socket. It preserves local project configuration and uses stock helper paths.

Embedded backends, daemon startup/restart/update, managed-worktree startup and
self-update are blocked. Failure after frontend exec exits that frontend; it
never falls back or replays accepted input. There is no output filtering, global
hook registration, launcher/profile replacement or extra perpetual service.

SessionConfigured publishes the actual selected session and cwd through the
existing verified per-surface protocol, with fresh wrapper PID/invocation
metadata. Public readback must confirm the saved binding. There are at most
three short delivery attempts; selecting another chat cancels the prior helper.
The helper cannot submit work. This supplies restoration metadata; it does not
restart a model turn. Global auto-resume remains a separate setting.

## Build and maintain

`source.json` pins upstream and orders all patches. Dispatch **Quiet Codex
rendering proof** on the selected source branch with `build_frontend=true`.
The lane validates seven original rendering cases, attach boundaries, five
binding cases (including declined delivery/retry against a fake CLI), and four
focus cases before/after their patch. Regression failures must be executed test
failures, never compilation errors. Release compilation belongs on GitHub,
not the 8 GB workstation. No account/model turns are used by this lane.

Select that run in **Personal cmux updates**, input `quiet_frontend_run`, on the
same source branch. Native and Rust builds can run concurrently. Candidate
packaging verifies the upstream pin, ordered patch hashes, binary checksum,
architecture and signature, then bundles the frontend with its license/manifest.
The CLI equivalent is `scripts/personal-package.py <candidate-app>
--quiet-artifact <downloaded-artifact-directory>`. Without that argument the
candidate omits the derived frontend. Installing never happens automatically.

Settings shows bundled/installed versions, checks compatibility, and opens the
build/update workflow. Stock Codex updates normally. A new version can use stock
until an agent reviews the new source pin, adapts patches, runs regressions and
bundles a replacement. The button does not automatically repatch arbitrary
upstream code, update Codex or replace a running app.

The app observes trusted cmux-owned chat IDs on the native coordinator's existing
connection. Read-only `thread/read` metadata and `thread/status/changed` cover
phone activity while a frontend sleeps or closes. Transport loss is unknown;
bounded reconnects never resume threads, restart the daemon or retry prompts.
Positive native activity remains a fallback when stock clients switch chats
without publishing fresh identity. **Working First** is a separate sidebar
ordering mode; **Agent Activity** retains event-based promotion.

Before opt-in installation, verify the compiled frontend in an owned terminal,
including Ctrl+T, phone steering, native computer use and resource use. Never
restart the stock daemon, resubmit active work or replace an occupied app to test.

Prompted by [Codex issue 18396](https://github.com/openai/codex/issues/18396) and
[WladmirJunior's focus prototype](https://github.com/WladmirJunior/codex/commit/18208da18be401804c4ae48ea6533193d56371b3).
This implementation does not copy its global configuration, model instructions,
commentary suppression or failed-command hiding policy.
