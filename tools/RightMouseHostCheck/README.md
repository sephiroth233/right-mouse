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

The harness provides local APFS/process-level evidence. It does not establish
Finder extension transport, App Group signing, sandbox/TCC behavior,
multi-volume semantics, external-volume behavior, or visible UI correctness.
