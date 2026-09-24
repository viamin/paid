# EARS Specs: Project Creation (Blank Repositories)

> Testable claims for creating new projects from blank GitHub repositories
> (issue #3954). Status markers: `[x]` implemented, `[ ]` active gap,
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r PROJECT-CREATION-001`).

## Creation option

- [x] **PROJECT-CREATION-001** - When the add-project page is rendered, the
  system SHALL offer both connecting an existing repository and creating a new
  (blank) repository, with the credential selectors shared by both modes.
  *Tests:* `spec/requests/projects_spec.rb` ("GET /projects/new" create-mode
  assertions). *Code:* `app/views/projects/new.html.erb`,
  `app/javascript/controllers/project_creation_mode_controller.js`.

- [x] **PROJECT-CREATION-002** - When a project is created in create mode with
  a selected active credential, an authorized owner, and a valid repository
  name, the system SHALL create a blank GitHub repository under that owner
  using the selected PAT or GitHub App installation and persist the matching
  Paid project with the repository metadata returned by GitHub. Inactive PATs
  SHALL be rejected before any GitHub write.
  *Tests:* `spec/requests/projects_spec.rb`,
  `spec/services/projects/create_blank_spec.rb`.
  *Code:* `ProjectsController#create_blank_project`, `Projects::CreateBlank`,
  `GithubClient#create_repository`.

- [x] **PROJECT-CREATION-003** - When a blank project is created, the system
  SHALL record `creation_origin: "blank"` and `setup_status: "pending"` and
  apply the same tenant project defaults and standard labels as the connect
  path.
  *Tests:* `spec/services/projects/create_blank_spec.rb`.
  *Code:* `Projects::CreateBlank`.

- [x] **PROJECT-CREATION-004** - The system SHALL reject create-mode requests
  whose target owner is not authorized for the selected credential (PAT: the
  authenticated login or one of its organizations; installation: the
  installation account login) *before* any GitHub write occurs.
  *Tests:* `spec/services/projects/create_blank_spec.rb` ("owner" contexts).
  *Code:* `Projects::CreateBlank`.

- [x] **PROJECT-CREATION-005** - The system SHALL reject repository names that
  violate GitHub naming rules, and owner/repo pairs that already exist as
  projects in the account, before creating anything on GitHub.
  *Tests:* `spec/services/projects/create_blank_spec.rb`,
  `spec/services/github_client_spec.rb`.
  *Code:* `Projects::CreateBlank`, `GithubClient` name guard.

- [x] **PROJECT-CREATION-006** - When a GitHub API error occurs during
  repository creation or GitHub App installation-token provisioning, the
  system SHALL surface the error on the add-project form without persisting a
  Paid project.
  *Tests:* `spec/requests/projects_spec.rb` ("POST /projects" create mode
  error contexts), `spec/services/projects/create_blank_spec.rb`.
  *Code:* `ProjectsController#create`, `Projects::CreateBlank`.

## Bootstrap guidance

- [x] **PROJECT-CREATION-007** - When a blank project's `setup_status` is not
  `completed`, the project page SHALL display a setup banner recommending chat
  as the default channel and linking the questionnaire and GitHub bootstrap
  issue alternatives.
  *Tests:* `spec/requests/projects_spec.rb` (setup banner contexts).
  *Code:* `app/views/projects/_setup_banner.html.erb`,
  `Project#setup_pending?`.

- [x] **PROJECT-CREATION-008** - When a blank project is created, the system
  SHALL create a GitHub bootstrap issue whose body contains the grill-me
  setup questionnaire; failure to create the issue SHALL NOT fail project
  creation.
  *Tests:* `spec/services/projects/create_blank_spec.rb` (bootstrap issue
  contexts). *Code:* `Projects::CreateBlank#create_bootstrap_issue`.

- [x] **PROJECT-CREATION-009** - When the user starts chat setup for a
  pending blank project, the system SHALL create a project-scoped chat
  session whose standard system prompt includes the grill-me bootstrap
  questionnaire, mark the project's `setup_status` as `in_progress`, and
  redirect into the session.
  *Tests:* `spec/requests/projects_spec.rb` ("start_setup_chat").
  *Code:* `ProjectsController#start_setup_chat`,
  `ChatSessions::BuildSystemPrompt`, `Projects::BuildSetupPrompt`.

- [x] **PROJECT-CREATION-010** - When a chat session is created for a project
  whose `setup_status` is `pending`, the generated system prompt SHALL include
  the bootstrap questionnaire section, so fresh projects can also be set up
  from a new chat.
  *Tests:* `spec/services/chat_sessions/build_system_prompt_spec.rb`.
  *Code:* `ChatSessions::BuildSystemPrompt`.

- [x] **PROJECT-CREATION-011** - The project's `setup_status` SHALL reach
  `completed` when a context-intake session for the project completes or when
  the user explicitly finishes setup from the banner.
  *Tests:* `spec/models/context_intake_session_spec.rb`,
  `spec/requests/projects_spec.rb` ("finish_setup").
  *Code:* `ContextIntakeSession#complete!`, `ProjectsController#finish_setup`.
