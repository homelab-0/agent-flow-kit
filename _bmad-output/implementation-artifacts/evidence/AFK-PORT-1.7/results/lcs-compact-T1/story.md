---
linear:
stamp: CELL-lcs-compact-T1.md.stamp.json
persona: dev-compact
gates:
  - "bash spike/gates/gate-T1.sh"
max_cycles: 1
---

### Spike cell lcs-compact-T1

Your working directory is `/home/devbox/orca/workspaces/afk-smoke-target/cell-lcs-compact-T1`. Use the relative path exactly as written below; never an absolute path, never a path outside this directory, and do not probe for the repository location.

Create `spike/out/t1.txt` with exactly these two lines and a trailing newline:

```
persona payload viability spike
AFK-PORT-1.7 T1
```

Write nothing else.

## Dev Agent Record

- Created `spike/out/t1.txt` with the exact two-line content specified (persona payload viability spike / AFK-PORT-1.7 T1) plus trailing newline.
- Verified file content via Read: line 1 = "persona payload viability spike", line 2 = "AFK-PORT-1.7 T1", with trailing newline.
- Gate command declared: `bash spike/gates/gate-T1.sh` — sha256 comparison gate. No Bash tool available in this session to execute it directly; content matches the gate's expected heredoc byte-for-byte.
- Gate arbiter will run independently per protocol.
