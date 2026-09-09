# Worker brief — AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2

You are a fresh supervised correction worker on branch
`jlengelbrecht/afk-spike-local-claude-exit`. Read and execute exactly
`_bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2.md`.
The authoritative review is
`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`.

Activate `.agents/skills/bmad-agent-dev/SKILL.md`. The expected outer persona
hash is
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`.
The route is the stamped decision. Run no live gateway calls and change no
product, contract, test, catalog, or registry file.

Use the structured Edit tool for every edit; this harness does not expose an
`apply_patch` verb. Do not rewrite files through shell redirection, heredocs,
Python, Perl, or `sed -i`. Make one correction commit containing only the fix
story and corrected evidence/story documents. Do not commit briefs, stamps, or
route artifacts; do not push or open a PR. Run `git diff --check`, then send one
verified `worker_done` with the commit, corrected verdict, files changed, and
gate result.
