---
name: check-runtime-reflection
description: >
  Verify that code changes are actually reflected in a running process via the
  /proc/<PID>/fd/<N> mechanism. Trigger: "check runtime reflection", "process reflection",
  "verify code in running process", "実行中プロセスへの反映確認"
---

# /check-runtime-reflection — Runtime Code Reflection Verification

## Overview

This tool checks whether code modifications have been reflected in a running process
by examining the process's file descriptor via `/proc/<PID>/fd/<N>`. It reads the
inode directly and searches for expected strings, bypassing static assumptions about
deployment status. Essential for confirming that a long-running daemon has picked up
new code after a deploy.

## When to Use

Use this tool when:
- You've deployed new code but a running process appears to still execute old code
- You need decisive proof that a code change is (or isn't) reflected in a running daemon
- Static assumptions fail: e.g., "the file was updated, so the process must have it"
  is unreliable for processes that were started before the update
- You want to measure the time lag between deployment and runtime reflection

Example scenarios:
- Verifying that a hotfix for `inbox_watcher.sh` is running in the karo agent's process
- Confirming that new fleet idle detection code is executing in the watcher
- Debugging a stale process that continues running old code hours after deployment

## Instructions

### Basic Usage

```bash
scripts/check_runtime_reflection.sh <PID> <search_string> [--fd=<N>] [--min-count=<N>]
```

### Arguments

- **`<PID>`** (required): Process ID to check. Find it with `ps aux | grep <name>`.
- **`<search_string>`** (required): String to search for in the process's file descriptor.
  Typically a function name, variable name, or error message from your new code.
- **`--fd=<N>`** (optional, default `255`): File descriptor number to examine.
  Most long-running shell scripts use FD 255 (the script file itself). Check with
  `ls -la /proc/<PID>/fd/` to find the right FD.
- **`--min-count=<N>`** (optional, default `1`): Minimum occurrences of the search
  string required to count as "reflected". Useful if the string appears multiple times
  and you want to verify a threshold.

### Output

The tool prints one of three outcomes to stdout:

| Outcome | Exit Code | Meaning |
|---------|-----------|---------|
| `REFLECTED` | 0 | The search string was found in the process's FD (code is active) |
| `NOT_REFLECTED` | 1 | The FD exists and is readable, but the search string was not found |
| `UNKNOWN` | 2 | The process, FD, or grep check failed; cannot determine status |

Diagnostic messages (fd state, error details) go to stderr.

### Concrete Example

```bash
# Scenario: We deployed changes to scripts/inbox_watcher.sh.
# The process (PID 2178) should have the new function "check_fleet_idle_notify".
# We need to verify it's actually running the new code.

scripts/check_runtime_reflection.sh 2178 check_fleet_idle_notify

# Output:
# REFLECTED
# (exit code: 0)
# stderr: info: fd_state=not_deleted (lrwx------ 1 karo karo 64 ... /proc/2178/fd/255 -> /home/.../scripts/inbox_watcher.sh)

# Interpretation: The inbox_watcher process is running code that includes the
# "check_fleet_idle_notify" function, confirming the deployment is live.

# Counter-example (old code still running):
scripts/check_runtime_reflection.sh 2178 check_fleet_idle_notify

# Output:
# NOT_REFLECTED
# (exit code: 1)
# stderr: info: fd_state=deleted (lrwx------ 1 karo karo 64 ... /proc/2178/fd/255 -> /home/.../scripts/inbox_watcher.sh (deleted))

# Interpretation: The FD shows "(deleted)" — the process is running a file that
# no longer exists on disk. The new code was deployed to a different location
# (or the inode was replaced). The process needs to be restarted to pick up the
# new version.
```

### Common Patterns

**Verify multiple changes at once:**
```bash
# Check if ANY of three new functions are present
for func in build_fleet_idle_message check_fleet_idle_notify fleet_idle_trigger; do
  scripts/check_runtime_reflection.sh $PID "$func" && break
done
```

**Batch verification across multiple processes:**
```bash
ps aux | grep "inbox_watcher" | grep -v grep | awk '{print $2}' | while read pid; do
  echo -n "PID $pid: "
  scripts/check_runtime_reflection.sh "$pid" "new_feature_marker"
done
```

**Monitor reflection lag after deployment:**
```bash
# Measure time until the process reflects new code
START=$(date +%s)
while true; do
  if scripts/check_runtime_reflection.sh 2178 "new_marker" >/dev/null 2>&1; then
    ELAPSED=$(($(date +%s) - START))
    echo "Reflection detected after ${ELAPSED} seconds"
    break
  fi
  sleep 1
done
```

---

## Notes

- **FD 255 assumption**: Most bash scripts use FD 255 for the script file itself.
  If your script uses a different FD, adjust accordingly. List all FDs with
  `ls -la /proc/<PID>/fd/`.

- **"(deleted)" flag**: If `ls -la /proc/<PID>/fd/255` shows `(deleted)`, the
  process is running a file that has been unlinked or replaced. This is common
  after a deployment and typically indicates the process needs restarting to
  reflect new code.

- **Dynamic scripts and sourced files**: If your main script sources other files
  with `. source.sh`, the sourced code is embedded in the main script's process
  memory. Searching FD 255 will find changes to the main script but not to
  independently-sourced files unless they were re-sourced.

- **Binary processes**: This tool only works for text-based file descriptors
  (shell scripts, configuration files). Binary executables won't contain your
  search strings in a human-readable form.
