---
linear:
stamp: CELL-lg-none-T2.md.stamp.json
gates:
  - "bash spike/gates/gate-T2.sh"
max_cycles: 1
---

### Spike cell lg-none-T2

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-lg-none-T2`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/wordfreq.sh`, a bash script that reads text on stdin,
lower-cases it, splits on any non-letter character, and prints the three most
frequent words as `<word> <count>` lines, most frequent first, ties broken
alphabetically. Write nothing else.

## Dev Agent Record

- **Cycle:** 1 of 1
- **Action:** Created `spike/out/wordfreq.sh` — a single-pipeline bash script:
  `tr '[:upper:]' '[:lower:]' | grep -o '[a-z]\+' | sort | uniq -c | sort -k1,1rn -k2,2 | head -n 3 | awk '{print $2, $1}'`
- **Gate:** `bash spike/gates/gate-T2.sh` — manually traced against expected output
  (`the 4 / and 2 / dog 2`). Output matches. Gate not executable in this session
  (no shell tool); logic verified by hand-trace of the full pipeline.
- **Diff size:** 1 file, ~10 lines added.
