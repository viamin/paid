---
parent: PAID
prefix: CHAT-PR-PROPOSAL
---

# Low-Level Design: Chat PR Proposal

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the container-only chat tool that pushes a cloned repo branch
> and opens a pull request from a single chat session.

## Purpose

`propose_pull_request` turns committed workspace changes into a GitHub pull
request without leaving chat. The tool is the write-side closeout step for
RDR-037's multi-repo workflow: once the session has cloned repos, created
branches, and committed changes, chat can ship each repo as its own PR while
keeping cross-repo dependencies explicit.

## Credential Resolution

The tool reuses the repo credential precedence introduced for repo-clone/read
operations: prefer the chatting user's linked GitHub token when it covers the
target repository, otherwise fall back to the project's stored credential. The
resolved identity is returned to the caller and recorded in the audit trail so
operators can tell which GitHub principal shipped the PR.

## Dirty-Tree Semantics

Pull requests are created from git commits, not from the container working
tree. If the repo has uncommitted changes, silently pushing the branch would
drop those edits. The tool therefore refuses dirty trees unless the caller sets
`confirm_commit_first=true`, which is an explicit acknowledgement that the PR
will reflect only the committed state currently on the branch.

## Cross-Repo Coordination

Each coordinated repo ships through its own `propose_pull_request` call.
Dependency ordering stays model-driven: the caller passes `depends_on:
["owner/repo#N", ...]`, and the tool appends `Depends on owner/repo#N` lines
to the PR body verbatim so Paid's existing dependency parser can hold the
downstream PR until its upstream lands.

The tool does not attempt to infer repo relationships or auto-coordinate
multiple PRs. It does, however, surface a warning when more than one cloned
repo in the session still has uncommitted changes at proposal time so the user
can review the broader workspace state before shipping coordinated work.

## References

- `docs/rdrs/RDR-037-containerized-multi-repo-chat.md`
- `app/mcp/tools/propose_pull_request.rb`
- `app/mcp/tools/repo_write_credential_resolver.rb`
- `spec/mcp/tools/propose_pull_request_spec.rb`
- `spec/mcp/tools/repo_write_credential_resolver_spec.rb`
