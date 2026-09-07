---
linear:
stamp: CELL-cs-full-T2.md.stamp.json
persona: dev-full
gates:
  - "bash spike/gates/gate-T2.sh"
max_cycles: 1
---

### Spike cell cs-full-T2

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-cs-full-T2`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/wordfreq.sh`, a bash script that reads text on stdin,
lower-cases it, splits on any non-letter character, and prints the three most
frequent words as `<word> <count>` lines, most frequent first, ties broken
alphabetically. Write nothing else.

### Dev Agent Record

**Files changed**
- `spike/out/wordfreq.sh` (new, 16 lines) — the whole deliverable. Diff size: 1 file, 16 added lines.

**Implementation**
A single shell pipeline: `tr` folds to lower case, `tr -cs 'a-z' '\n'` splits on
runs of non-letters, `grep -v '^$'` drops the empty trailing field, then
`sort | uniq -c` counts and `sort -k1,1nr -k2,2` orders by count descending with
alphabetical tie-breaking. `LC_ALL=C` pins collation so the tie order does not
depend on the caller's locale.

Truncation to three lines is done by `awk 'NR <= 3'` rather than `head -n 3`.
`head` closes the pipe early, which can SIGPIPE the upstream `sort`; under
`set -o pipefail` that makes the whole pipeline exit non-zero on a large enough
input, and the gate treats a non-zero exit as a failure. `awk` consumes all its
input, so no stage is ever killed.

**Gate status — NOT RUN BY ME**
`bash spike/gates/gate-T2.sh` was not executed: this session was invoked without
a shell tool (only file read/write/search were available), so I had no way to run
it. I did not have any command execution available at any point, so there is no
gate evidence to attach. Per the brief the gates are the arbiter and are re-run
independently; that independent run is the only verification of this change.

What I verified by hand instead, tracing the gate's own fixture
`the cat and the dog and the bird. The DOG!`:
- after folding and splitting: `the cat and the dog and the bird the dog`
- counts: `the 4`, `and 2`, `dog 2`, `bird 1`, `cat 1`
- after `sort -k1,1nr -k2,2`: `the 4` / `and 2` / `dog 2` / `bird 1` / `cat 1`
  (`uniq -c`'s leading blanks are skipped by `sort`'s default field parsing)
- first three, reformatted by awk: `the 4`, `and 2`, `dog 2` — the expected output.

The script writes nothing to stderr, which matters because the gate captures
`2>&1` into the compared string.
