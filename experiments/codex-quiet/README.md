# cmux quiet Codex frontend

This is a maintained, cmux-bundled derivative of the pinned Codex TUI. It attaches
to the existing stock managed daemon. The ordinary `codex` executable, official
apps, global configuration and phone access are unchanged.

`terminal.codexQuietFrontend` defaults off. Enable **Hide Codex Tool Calls** in
Terminal settings, open a new cmux terminal, and run normal `codex`. Positively
identified routine agent commands, successful file edits, web search/open/find,
image-view bookkeeping, text MCP/dynamic calls and native computer activity
(including returned screenshots) occupy no transcript rows. **Ctrl+T** switches
between true quiet and the original compact view. Assistant messages, user shell
commands, failures, approvals, questions, unknown tool/media content and meaningful
status stay visible. User images and generated assistant image artifacts remain
visible. Full-content search and F4 retain the original tool data.

## Tool coverage at the pinned source

The inventory covers all 40 `HistoryCell` implementations in `history_cell/`
and `exec_cell/render.rs`. Quiet classification defaults to visible; it does not
inspect rendered wording, strip terminal output, or hide arbitrary media.

| Cells | Quiet behavior |
| --- | --- |
| `ExecCell` | Hide active/successful agent command, read/list/search and polling groups; preserve user shell, nonzero exits and interruption. |
| `PatchHistoryCell`, `PatchFailureCell` | Hide successful add/update/delete/rename summaries and diffs; preserve failed patch diagnostics. |
| `WebSearchCell`, `ViewImageHistoryCell` | Hide known search/open/find activity and viewed-image metadata; preserve unknown web actions. The pinned web cell has no failure status; separate diagnostics stay visible. |
| `McpToolCallCell`, `ComputerActivityCell`, `DynamicToolCallCell` | Hide active/successful text calls and grouped native `cua_repl` activity, including its screenshot results. Preserve transport/tool errors, interruptions, other media, resources and unknown blocks. |
| `CompositeHistoryCell`, `ActivityDetails`/`ActivityGroup` | Recurse through known routine members. Preserve protected descendants; show retained group details when they contain assistant content or errors. Transcript-only reasoning and terminal bookkeeping remain in backing content. |
| `PlanUpdateCell` | Hide routine plan-tool checklists; preserve authored proposed plans and streamed plan text. |
| `ImageGenerationHistoryCell`, user/assistant message and authored plan cells | Preserve generated artifacts, image attachments, spoken artifact links, chat, final results and proposed plans. |
| Plain/wrapped/link cells, requests/approval results, hooks, warnings, safety, session, recap, update and separator cells | Preserve upstream behavior. Explicit `/ps` process summaries stay visible; `UnifiedExecInteractionCell` remains transcript-only. |

`tool-coverage-tests.patch` appends dedicated retained/live rendering fixtures
after the original twelve patches. `tool-coverage.patch` adds the classification
and shared group presentation. Both proof entrypoints require the same 21 tests
to fail behaviorally before the fix, pass after it, and pass with the feature
disabled. Fixtures cover active/completed calls, five-action computer groups,
screenshots, two-file edits, nested protected content, repeated Ctrl+T-equivalent
toggles, clearing stale live expansion when entering quiet mode, search and
detailed/raw backing content. Hooks already discard routine context-only success
upstream; warning/error/stop/feedback output remains visible even on a Completed
status. Rust execution belongs to CI;
Python gate tests and patch/syntax checks alone do not establish those results.

The derived frontend also suppresses the recurring **Working** tip. Startup and
completion guidance stays available. With **Background Agent Coordination**
enabled, new cmux-owned Codex threads receive a scoped coordination tool and a
passive worker row above the composer. Existing resumed threads retain their
original tools. [Coordination controls and limits](../../docs/agent-messages.md)
include headless workers, exact-session follow-ups, passive receipts and finite
schedules; they do not install global hooks or a scheduling daemon.

## Launch boundaries

Plain interactive launch, `resume` and an explicit resume UUID are supported,
with a narrow set of model, cwd, sandbox and approval flags. The exact native
restore lane also accepts `--yolo` and only the supported update-check/effort
config keys, preserving original permission choices. Other flags, prompts
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
focus cases before/after their patch, plus Working-tip, orchestration and
restore-compatibility regressions with feature-off controls. Regression failures must be executed test
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
