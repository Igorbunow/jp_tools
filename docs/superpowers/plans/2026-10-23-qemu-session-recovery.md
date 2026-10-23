# QEMU Session Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rootfs APT and interactive QEMU sessions recover cleanly after success, failure, signals, or terminal loss, and detect sessions left by an earlier run.

**Architecture:** A Bash session helper will hold a per-deployment `flock` lock and record the owning PID, rootfs path, and phase. Before starting a QEMU operation, the setup script will inspect the lock, matching chroot processes, mountpoints, and resolver backup markers. Interactive mode will ask before terminating an existing session; batch mode will require `--force-qemu-cleanup`. Cleanup will run before releasing the lock and preserve recovery metadata if it fails.

**Tech Stack:** Bash, util-linux (`flock`, `setpriv`), `sudo`, shell tests in `tests/x86`.

**Spec:** User request in this conversation: exercise normal and failure exits for APT and QEMU, detect sessions left after terminal closure, prompt in interactive mode, and require an explicit force option in batch mode.

## Global Constraints

- Every script message must remain in English.
- Do not flash hardware or run package updates during tests.
- Test process termination and mount cleanup only in temporary fixtures.
- Never terminate an unrelated process; match the stored session PID or exact rootfs path.
- Batch cleanup requires the explicit `--force-qemu-cleanup` flag.
- Preserve the active deployment's original `/etc/resolv.conf` and all mount state.

## Review Focus

- A live new-version lock is present: reject by default; prompt interactively or terminate only with explicit batch force.
- A legacy orphaned chroot has no lock but still has a process or mounted rootfs: detect by exact rootfs path and recover safely.
- No live process remains but resolver backup or mounts remain: offer/restrict cleanup according to mode.
- APT, mount, or umount returns nonzero: retain useful failure state and never claim clean completion.
- SIGINT, SIGHUP, SIGTERM, or terminal loss during either stage: cleanup and release the lock, or leave detectable metadata for the next run.

---

### Task 1: Session lock and stale-state recovery

**Files:**
- Create: `lib/qemu_session.sh`
- Modify: `setup_jetson.sh`
- Test: `tests/x86/test_qemu_session.sh`

**Interfaces:**
- `qemu_session_begin <lock-file> <rootfs> <interactive> <force>` acquires/reclaims a session or returns nonzero.
- `qemu_session_set_phase <phase>` updates the lock metadata.
- `qemu_session_end <clean>` releases the lock and clears metadata only after successful cleanup.
- `setup_jetson.sh` supplies `confirm` and `cleanup_qemu_rootfs` callbacks.

- [x] Write tests for free lock, live lock, interactive decline/accept, batch rejection, batch force, orphan artifacts, and exact-path process matching.
- [x] Run the session test before implementation (it failed because the session module was absent).
- [x] Implement lock metadata, bounded termination escalation, stale artifact detection, and mode-specific behavior.
- [x] Run the session tests and existing shell tests.

### Task 2: Wire APT and interactive QEMU lifecycle

**Files:**
- Modify: `setup_jetson.sh`, `lib/qemu_apt.sh`, `lib/qemu_resolv.sh`
- Test: `tests/x86/test_qemu_cleanup.sh`, `tests/x86/test_qemu_apt.sh`

**Interfaces:**
- Both `update_rootfs_packages` and `setup_qemu_chroot` acquire a session before modifying rootfs state.
- Cleanup status is checked before session metadata is cleared.
- Signal handlers terminate child chroot processes, clean mounts/resolver, release the session, then exit with a signal-derived status.

- [ ] Add tests for APT update/upgrade/install failure, mount failure after each mount, umount failure, normal shell exit, shell nonzero exit, and signal cleanup.
- [ ] Verify tests fail before lifecycle changes.
- [x] Wire lifecycle state, preserve precise failing stage/code, and invoke cleanup on every return/signal path.
- [ ] Run tests and validate no temporary mount or resolver artifact remains in fixtures.

### Task 3: CLI and documentation

**Files:**
- Modify: `setup_jetson.sh`, `README.md`, `README.ru.md`, `docs/USAGE.en.md`, `docs/USAGE.ru.md`
- Test: `tests/x86/test_setup_paths.sh`, `tests/x86/test_qemu_session.sh`

- [x] Test parsing/help for `--force-qemu-cleanup` and batch behavior.
- [x] Document interactive recovery prompt, batch refusal without the flag, and the flag's exact effect.
- [x] Run the full shell suite, Bash syntax checks, English-output scan, and `git diff --check`.
- [x] Confirm no active QEMU/setup process or mount remains on the working deployment.
