`spike/matrix.yaml` is the benchmark matrix: the local profiles and vendor
baselines under test, crossed with three persona modes (full, compact, none)
and three canary tasks (T1, T2, T3), plus how each measurement is derived.
A cell is composed from a task body in `spike/tasks/` plus per-cell frontmatter
the coordinator prepends, naming `persona: dev-full`, `persona: dev-compact`,
or omitting the persona key entirely for the `none` mode.
The coordinator runs each cell through the kit's canonical dispatch path,
scores the output with the matching `spike/gates/gate-T*.sh`, and records the
results under `spike/results/`.
