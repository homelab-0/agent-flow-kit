---
linear:
stamp: CELL-os-none-T2.md.stamp.json
gates:
  - "bash spike/gates/gate-T2.sh"
max_cycles: 1
---

### Spike cell os-none-T2

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-os-none-T2`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/wordfreq.sh`, a bash script that reads text on stdin,
lower-cases it, splits on any non-letter character, and prints the three most
frequent words as `<word> <count>` lines, most frequent first, ties broken
alphabetically. Write nothing else.

## Dev Agent Record

### Status

Complete.

### Implementation

- Added `spike/out/wordfreq.sh` to normalize ASCII letters to lower case, split
  input on non-letters, count words, and emit at most three results ordered by
  descending frequency and then alphabetically.
- Fixed the processing locale to `C` so letter classification and alphabetical
  tie-breaking are deterministic.

### Gate Results

- `bash spike/gates/gate-T2.sh` — PASS.

### Files Changed

- `spike/out/wordfreq.sh` (new implementation)
- `stories/CELL-os-none-T2.md` (this Dev Agent Record)

### Final Diff Size

- Implementation: 1 new file, 11 lines.
- Dev Agent Record: 23 appended lines.
