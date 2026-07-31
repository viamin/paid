# Intent tree

This directory holds the LID arrow below the high-level design: one folder per
design node, each containing a low-level design (`*-design.md`) and its EARS
specs (`*-specs.md`).

```
docs/
├── high-level-design.md          # HLD — the why (root of the tree)
└── intent/
    └── <segment>/                # one folder per design node
        ├── <segment>-design.md   # LLD — the how
        └── <segment>-specs.md    # EARS — testable claims
```

## Conventions

- **IDs are path-concatenated.** A spec ID is the root-to-leaf path plus a
  number, e.g. `AGENT-RUN-001`. Deeper nesting extends the path one segment at
  a time (`AGENT-RUN-COST-003`). A prefix-grep gathers an entire subtree:
  `grep -r AGENT-RUN` returns every spec, test, and code anchor beneath that
  node.
- **LLD frontmatter** declares `parent:` (the node above) and `prefix:` (the
  EARS ID prefix for the node's specs).
- **EARS specs** state one testable claim per line. Status markers:
  `[x]` implemented · `[ ]` active gap · `[D]` deferred.
- **`@spec` annotations** in code and tests link back to the EARS IDs they
  implement. A spec ID is a grep target — `grep -r AGENT-RUN-001` returns the
  requirement, the tests asserting it, and the code implementing it.
- **Tests before code.** Write the failing-first test that asserts the EARS
  claim before the implementation.
- **Mutation, not accumulation.** Docs carry *current* intent, written to be
  read cold. Delete obsolete specs rather than annotating history.

## Going-forward policy

This is a brownfield, Full-mode adoption. The HLD is the floor; segments are
added as new features are built and as existing subsystems are mapped over
time. It is expected that much of the existing codebase is not yet traced. When
you build or change a component, add or update its segment here so the arrow
stays walkable from that point forward.

## When to add a segment

- **New feature or component** → add `<segment>/<segment>-design.md` +
  `<segment>-specs.md` before (or alongside) the code.
- **Substantive change to an existing component** → update its LLD and specs,
  then cascade to tests and code.
- **Bug fix** → find where intent diverged (which spec/LLD it traces to), fix
  the intent there, and cascade. No short-circuit straight to code.
- **Trivial change** (typo, formatting, broken link) → no segment work needed.

For the full workflow and the `## LID` mode declaration, see `CLAUDE.md`
(canonical; `AGENTS.md` is a symlink).
