# Quiet fullscreen rendering experiment

This is a test-only adaptation of Codex 0.164.0's own TUI layout. The workflow
checks out the immutable upstream commit in `source.json`, applies regression
tests against existing rendering APIs, requires an executed behavioral failure,
then applies the presentation patch and reruns those same tests. All tool inputs
and results are synthetic. No model account, conversation, daemon or local
installation is used. No frontend is packaged or installed by this lane.

Push this experiment branch to run `Quiet Codex rendering proof`. The resulting
artifact contains the stock and patched test logs. Setup failures, compilation
errors, skipped tests and zero executed tests do not satisfy the regression gate.
Do not compile this experiment on the 8 GB workstation.

The initial cohort covers agent shell commands, text-only MCP calls and dynamic
tool calls. A short tool name/status replaces arguments and output in compact
fullscreen presentation. Original transcript cells and expanded details remain.
Unknown items, explicit user-shell commands, approvals/questions and media stay
on their existing presentation paths. This is deliberately narrower than a
complete quiet frontend.

A usable cmux-bundled frontend still requires a separately validated attach-only
stock-daemon boundary, stock-compatible interactive argument routing, version
gating and pre-submission fallback. This rendering proof does not establish phone,
native computer-use, memory or signed-app compatibility. It must not be used as
a replacement for the installed `codex`.

The investigation was prompted by
[Codex issue 18396](https://github.com/openai/codex/issues/18396) and
[WladmirJunior's focus prototype](https://github.com/WladmirJunior/codex/commit/18208da18be401804c4ae48ea6533193d56371b3).
It does not copy the prototype's configuration, model instructions, commentary
suppression or failed-command hiding policy.
