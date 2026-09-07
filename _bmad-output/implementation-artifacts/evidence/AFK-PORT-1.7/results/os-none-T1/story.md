---
linear:
stamp: CELL-os-none-T1.md.stamp.json
gates:
  - "bash spike/gates/gate-T1.sh"
max_cycles: 1
---

### Spike cell os-none-T1

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-os-none-T1`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/t1.txt` with exactly these two lines and a trailing newline:

```
persona payload viability spike
AFK-PORT-1.7 T1
```

Write nothing else.

## Dev Agent Record

- Created `spike/out/t1.txt` with the exact required two lines and trailing newline.
- Gate: `bash spike/gates/gate-T1.sh` — PASS.
