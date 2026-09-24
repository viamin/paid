---
parent: PAID
prefix: PROJECT-CREATION
---

# Low-Level Design: Project Creation (Blank Repositories)

> Companion to the high-level design (`docs/high-level-design.md`).
> Issue #3954. This segment covers creating *new* projects — a blank GitHub
> repository plus a Paid project — instead of only connecting an existing
> repository.

## Purpose

Paid's "Add Project" flow only supported connecting an existing GitHub
repository. Users starting from scratch had to leave Paid, create an empty
repo, and come back. This segment adds a create-new path: Paid provisions the
blank repository on GitHub (via the selected PAT or the paid-agents GitHub App
installation) and the matching Paid project in one step.

Because a freshly created repository has no tooling decisions recorded, agent
runs start from a blank slate: language/framework, dependencies, CI, and repo
conventions must be chosen before meaningful work can happen. The setup
decisions can be made through any of three channels — a GitHub bootstrap
issue, Paid's context-intake questionnaire ("grill me"), or interactive chat.
Chat is the default recommendation because the most context can be captured
interactively.

## Data model

Two columns on `projects`:

- `creation_origin` — `"connected"` (default; the repo already existed) or
  `"blank"` (Paid created the repository). Not nullable; existing rows are
  `connected` by definition.
- `setup_status` — `nil` for connected projects (setup not required); one of
  `"pending"`, `"in_progress"`, `"completed"` for blank projects. `pending` is
  set at creation; `in_progress` when a setup channel is started; `completed`
  when the context intake session completes or the user explicitly finishes
  setup.

## Creation path

`ProjectsController#create` branches on `params[:creation_mode]`. The
`"create"` branch delegates to `Projects::CreateBlank`:

1. Resolve the GitHub credential — a PAT (`GithubToken#client`) or a
   paid-agents App installation (an unscoped provisioning token via
   `Github::AppInstallation.provisioning_token_for`, wrapped in a
   `GithubClient`). The latter is necessary because GitHub cannot scope a
   token to a repository until that repository exists.
2. Validate the target owner against the credential: for a PAT the owner must
   be the authenticated login or an organization the token's user belongs to;
   for an installation the owner must be the installation's `account_login`.
3. Validate the repository name against GitHub's naming rules and reject
   owner/repo pairs that already exist as Paid projects in the account.
4. Create the repository through `GithubClient#create_repository`. Organization
   installations pass their authorized installation owner; user installations
   create under the authenticated user. The repo is created with `auto_init:
   true` so a default branch ref exists — Paid's worktree and branch machinery
   requires a base commit; a commit-less repository cannot host a run.
5. Persist the `Project` with metadata from the creation response
   (`github_id`, `default_branch`, `primary_language`), `creation_origin:
   "blank"`, `setup_status: "pending"`, then apply tenant project defaults
   and standard labels exactly like the connect path.
6. Best-effort: create a GitHub bootstrap issue whose body is the grill-me
   setup questionnaire (tooling choices). Failure here logs a warning and
   never fails project creation.

GitHub API failures (`NotFoundError`, `AuthenticationError`, `RateLimitError`,
`ApiError`, `Error`) are surfaced as form errors on the add-project page.

## Setup guidance

Blank projects with `setup_status` below `completed` render a setup banner on
the project page listing the three channels, with chat first (default
recommendation):

- **Chat** — `POST /projects/:id/start_setup_chat` creates a project-scoped
  `ChatSession` whose system prompt is the grill-me bootstrap questionnaire
  (`Projects::BuildSetupPrompt`), marks the project `in_progress`, and drops
  the user into the session. A chat created against a `pending` project by any
  other path (e.g. the new-chat modal) gets the same bootstrap section
  appended by `ChatSessions::BuildSystemPrompt`, so a fresh project can also
  be set up from a new chat.
- **Questionnaire** — links to the existing knowledge context-intake wizard,
  which is Paid's grill-me questionnaire infrastructure.
- **GitHub issue** — links to the bootstrap issue created in step 6; the
  trigger-run form path also works from that issue once it is labeled for
  pickup.

`Projects::BuildSetupPrompt` produces the questionnaire text (identity of the
blank repo, then the decision areas: language/framework, dependencies,
tooling, CI, testing, repo conventions, and working agreement), shared by the
chat system prompt and the GitHub bootstrap issue body.

`setup_status` reaches `completed` when a context-intake session for the
project completes, or when the user explicitly finishes setup from the banner
(`POST /projects/:id/finish_setup`).

## Trust and scope

- Repository creation is a write against the user's own GitHub credential;
  owner validation happens *before* any GitHub write so a token can never
  create a repo in an org it should not.
- The setup prompt contains no secrets and only references metadata Paid
  already stores (owner/repo name).
- Blank-project creation reuses the same policy checks as the connect path
  (`ProjectPolicy#create?`) and the same audit logging.
