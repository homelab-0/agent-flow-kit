---
linear:
stamp: CELL-lcs-none-T2.md.stamp.json
gates:
  - "bash spike/gates/gate-T2.sh"
max_cycles: 1
---

### Spike cell lcs-none-T2

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-lcs-none-T2`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/wordfreq.sh`, a bash script that reads text on stdin,
lower-cases it, splits on any non-letter character, and prints the three most
frequent words as `<word> <count>` lines, most frequent first, ties broken
alphabetically. Write nothing else.
