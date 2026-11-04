#!/usr/bin/env python3
"""Set each tracked file's mtime to the time of the last commit that touched it.

A fresh checkout stamps every file with "now", so a restored DerivedData sees
every source as newer than its build record and Xcode recompiles everything.
With commit times, files the change did not touch keep the timestamp they had
when the cache was built, and only the touched files (and their dependents)
recompile. Needs full history (actions/checkout fetch-depth: 0).
"""
import os
import subprocess

tracked = set(subprocess.run(
    ["git", "ls-files", "-z"], check=True, capture_output=True
).stdout.decode().split("\0")) - {""}

log = subprocess.Popen(
    ["git", "log", "--format=T %ct", "--name-only", "--no-renames", "-z", "HEAD"],
    stdout=subprocess.PIPE,
)
pending = set(tracked)
stamp = None
for chunk in log.stdout.read().decode().split("\0"):
    for line in chunk.split("\n"):
        if line.startswith("T "):
            stamp = int(line[2:])
        elif line in pending:
            os.utime(line, (stamp, stamp))
            pending.discard(line)
    if not pending:
        break
log.kill()
print(f"restored mtimes for {len(tracked) - len(pending)} of {len(tracked)} tracked files")
