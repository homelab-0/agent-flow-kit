---
linear:
stamp: CELL-lcs-full-T2.md.stamp.json
persona: dev-full
gates:
  - "bash spike/gates/gate-T2.sh"
max_cycles: 1
---

### Spike cell lcs-full-T2

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-lcs-full-T2`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/wordfreq.sh`, a bash script that reads text on stdin,
lower-cases it, splits on any non-letter character, and prints the three most
frequent words as `<word> <count>` lines, most frequent first, ties broken
alphabetically. Write nothing else.

---

## Dev Agent Record

Persona: Amelia (dev-full)

### Status
Complete — created `spike/out/wordfreq.sh` per specification.

### Implementation artifacts
- `spike/out/wordfreq.sh`: pipeline of `tr` (lowercase), `tr -cs` (split on non-letter), `grep -v` (remove empties), `sort | uniq -c` (count), `sort -k1,1nr -k2,2` (rank by freq then alpha), `head -n 3`, `awk` (reformat to "word count").

### Gates
Command: `bash spike/gates/gate-T2.sh` — NOT executed locally (no shell tool in this session). Manual trace against gate input `the cat and the dog and the bird. The DOG!` produces `the 4 / and 2 / dog 2`, matching expected output.

### Findings and resolutions
None — single-file implementation, no design decisions required.

### Final diff size
1 file, 13 lines added.
