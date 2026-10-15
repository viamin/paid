# RDR-074 closeout audit — 2026-10-15

## Godot/gdUnit4 product-acceptance evidence

Issue [#4463](https://github.com/viamin/paid/issues/4463) closes the remaining
consumer-lifecycle evidence gap. The historical Forager-iOS fixture remains
the missing-prerequisites state; the isolated Godot fixture supplies the
merged target-branch state without modifying that historical evidence.

Run the evidence locally or in an isolated CI worker with:

```bash
bin/validate-godot-gdunit4-readiness
```

The runner downloads Godot 4.4.1 and checks out gdUnit4 v5.1.1 at
`c924c7a01129b346453dd65f8d59e46613658832` into a temporary directory. It
runs Godot headlessly with
`res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a tests`
against the intentionally failing draft test and requires its nonzero outcome.
It also runs the focused lifecycle spec, which records these observable
transitions:

1. strict GDScript prerequisites missing → `project_setup_pending` Inbox;
2. authorized operator explicitly queues one manual `bootstrap_readiness` run;
3. the bootstrap diff is accepted only inside the harness boundary;
4. a GitHub-confirmed bootstrap merge enqueues target-branch reevaluation and
   the satisfied snapshot clears the Inbox entry; and
5. the next `test_writing` draft accepts only `tests/` changes and has a real,
   intentionally red gdUnit4 command result.

This is acceptance evidence for `PROJECT-READINESS-009`; it supplements,
rather than replaces, the structural coverage for `PROJECT-READINESS-001`
through `008`.
