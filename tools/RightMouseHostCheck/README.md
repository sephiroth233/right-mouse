# RightMouse Host integration check

This harness compiles the production `HostController`, `AppModel`, and
`ApplicationLauncher` against the real `RightMouseCore` module. It runs file
operations only in a fresh random directory under the system temporary folder.

Run from the repository root:

```sh
scripts/check-host.sh
```

The check disables Finder reveal behavior and avoids clipboard, application
launch, conflict dialogs, directory pickers, TCC changes, and user files. It
exercises interactive TXT and JSON creation, fixed-ID request deduplication,
copy, move, queued cancellation, receipts, crash-style recovery of an accepted
request, and isolation of a corrupt ledger record.

FollowupChecks adds real undo/restart, interrupted batch undo, persisted uncertain
intents, and failed-item retry checks. It verifies that the original receipt is
unchanged, repeated clicks do not create another child, and retry retains the
actual original destination. A permission fault temporarily changes only the
fixture Commands directory to 0500; after proving that rejected submission keeps
retry available and has no side effect, the test restores 0700 and retries.
Retry also rejects same-path replacement of either a failed source or the original
destination directory. Permission repair retains the same inode, bytes and mtime
and remains eligible for retry. Rejection preserves both objects and the original
receipt without creating child work.
The complete harness now passes 168 host-side checks: 153 real HostController
fixture assertions and 15 pure Open With planning assertions. ConflictChecks
adds durable waiting and batch decisions; RecentDestinationHostChecks adds
bookmarked target selection, invalid-reference refusal, repair and restart;
OpenWithHostChecks records the final OS application-open boundary to verify
project choice, cancellation, errors and directory identity without launching apps.

The harness provides local APFS/process-level evidence. It does not establish
Finder extension transport, App Group signing, sandbox/TCC behavior,
multi-volume semantics, external-volume behavior, or visible UI correctness.
