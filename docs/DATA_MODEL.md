# Paid Data Model

This document describes the database schema for Paid. The schema is designed around the principle that **configuration is data**—prompts, model preferences, and workflow parameters are all stored in the database, not in code.

## Entity Relationship Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CORE ENTITIES                                      │
│                                                                              │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐      ┌──────────┐        │
│  │ Account  │──────│   User   │      │  Project │──────│  Issue   │        │
│  └──────────┘      └──────────┘      └──────────┘      └──────────┘        │
│       │                 │                 │                  │              │
│       │                 │                 │                  │              │
│       │                 ▼                 ▼                  ▼              │
│       │           ┌──────────┐      ┌──────────┐      ┌──────────┐        │
│       │           │ Account  │      │  Style   │      │ AgentRun │        │
│       │           │Membership│      │  Guide   │      │          │        │
│       │           └──────────┘      └──────────┘      └──────────┘        │
│       │                                                      │              │
│       ▼                                                      ▼              │
│  ┌──────────┐                                          ┌──────────┐        │
│  │  GitHub  │                                          │  Token   │        │
│  │  Token   │                                          │  Usage   │        │
│  └──────────┘                                          └──────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         PROMPT SYSTEM                                        │
│                                                                              │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐      ┌──────────┐        │
│  │  Prompt  │──────│ Prompt   │──────│  ABTest  │──────│ ABTest   │        │
│  │          │      │ Version  │      │          │      │ Variant  │        │
│  └──────────┘      └──────────┘      └──────────┘      └──────────┘        │
│                          │                                   │              │
│                          ▼                                   ▼              │
│                    ┌──────────┐                        ┌──────────┐        │
│                    │ Quality  │                        │ Variant  │        │
│                    │ Metric   │                        │ Metric   │        │
│                    └──────────┘                        └──────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         MODEL SYSTEM                                         │
│                                                                              │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐                          │
│  │  Model   │──────│  Model   │──────│  Model   │                          │
│  │          │      │ Selection│      │ Override │                          │
│  └──────────┘      └──────────┘      └──────────┘                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Entities

### accounts

Organizations or teams that own projects. All resources belong to an account, enabling future multi-tenancy.

```sql
CREATE TABLE accounts (
  id            BIGSERIAL PRIMARY KEY,

  -- Identification
  name          VARCHAR(255) NOT NULL,
  slug          VARCHAR(100) NOT NULL UNIQUE,  -- URL-friendly identifier

  -- Settings (JSONB for flexibility)
  settings      JSONB DEFAULT '{}',
  -- Example settings:
  -- {
  --   "default_agent_type": "claude_code",
  --   "max_concurrent_agents": 5,
  --   "notification_email": "team@example.com"
  -- }

  -- Billing (for future use)
  plan          VARCHAR(50) DEFAULT 'free',    -- free, pro, enterprise
  billing_email VARCHAR(255),

  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_accounts_slug ON accounts(slug);
```

**Rails Model:**

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :account_memberships, dependent: :destroy
  has_many :members, through: :account_memberships, source: :user
  has_many :projects, dependent: :destroy
  has_many :github_tokens, dependent: :destroy
  has_many :prompts, -> { where(project_id: nil) }  # Account-level prompts
  has_many :style_guides, -> { where(project_id: nil) }  # Account-level guides

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9-]+\z/, message: "only lowercase letters, numbers, and hyphens" }

  before_validation :generate_slug, on: :create

  private

  def generate_slug
    self.slug ||= name.parameterize
  end
end
```

### users

Authenticated users belonging to an account.

```sql
CREATE TABLE users (
  id            BIGSERIAL PRIMARY KEY,
  account_id    BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,

  -- Authentication
  email         VARCHAR(255) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,

  -- Profile
  name          VARCHAR(255),
  avatar_url    VARCHAR(500),

  -- Status
  active        BOOLEAN DEFAULT TRUE,
  confirmed_at  TIMESTAMP,
  last_sign_in_at TIMESTAMP,

  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_account ON users(account_id);
CREATE INDEX idx_users_active ON users(account_id, active) WHERE active = TRUE;
```

**Rails Model:**

```ruby
# app/models/user.rb
class User < ApplicationRecord
  belongs_to :account
  has_many :account_memberships, dependent: :destroy
  has_many :member_accounts, through: :account_memberships, source: :account
  has_many :project_memberships, dependent: :destroy
  has_many :member_projects, through: :project_memberships, source: :project
  has_many :github_tokens

  validates :email, presence: true, uniqueness: true
  validates :account, presence: true

  # Devise for authentication
  devise :database_authenticatable, :registerable, :recoverable, :rememberable, :validatable
end
```

---

## Authorization (RBAC)

Paid uses explicit membership tables for role management and [Pundit](https://github.com/varvet/pundit) for authorization policies. This approach replaces the traditional Rolify gem with simpler, type-safe role management using Rails enums.

### Why Membership Tables Instead of Rolify?

1. **Type-safe enums** - Role values are validated by Rails enum declarations
2. **Simpler queries** - No polymorphic lookups required
3. **Better compatibility** - No circular require issues with Ruby 3.4+
4. **Explicit foreign keys** - Referential integrity enforced at database level
5. **Cleaner API** - Role methods defined directly on User model

### account_memberships

Represents a user's role within an account. Each user can have exactly one role per account.

```sql
CREATE TABLE account_memberships (
  id            BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id    BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role          INTEGER NOT NULL DEFAULT 0,  -- 0=viewer, 1=member, 2=admin, 3=owner
  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_account_memberships_user_account ON account_memberships(user_id, account_id);
CREATE INDEX idx_account_memberships_account_role ON account_memberships(account_id, role);
```

**Rails Model:**

```ruby
# app/models/account_membership.rb
class AccountMembership < ApplicationRecord
  belongs_to :user
  belongs_to :account

  enum :role, { viewer: 0, member: 1, admin: 2, owner: 3 }, validate: true
end
```

### project_memberships

Represents a user's role within a specific project. Allows fine-grained access control independent of account-level roles.

```sql
CREATE TABLE project_memberships (
  id            BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  project_id    BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  role          INTEGER NOT NULL DEFAULT 0,  -- 0=viewer, 1=member, 2=admin
  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_project_memberships_user_project ON project_memberships(user_id, project_id);
CREATE INDEX idx_project_memberships_project_role ON project_memberships(project_id, role);
```

**Rails Model:**

```ruby
# app/models/project_membership.rb
class ProjectMembership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  enum :role, { viewer: 0, member: 1, admin: 2 }, validate: true
end
```

### Defined Roles

| Role | Scope | Permissions |
|------|-------|-------------|
| `owner` | Account | Full access, can delete account, manage billing |
| `admin` | Account | Manage users, projects, settings; cannot delete account |
| `member` | Account | Add projects, run agents, view all account data |
| `viewer` | Account | Read-only access to projects and runs |
| `project_admin` | Project | Full control over specific project |
| `project_member` | Project | Run agents, view project data |

### Role Assignment Examples

```ruby
# Account-level roles
user.add_role(:owner, account)
user.add_role(:admin, account)
user.add_role(:member, account)

# Project-level roles (more granular)
user.add_role(:project_admin, project)
user.add_role(:project_member, project)

# Check roles
user.has_role?(:admin, account)
user.has_any_role?(:owner, :admin, account)
```

### Pundit Policies

```ruby
# app/policies/project_policy.rb
class ProjectPolicy < ApplicationPolicy
  def index?
    user_in_account?
  end

  def show?
    user_in_account? || user_has_project_role?
  end

  def create?
    user.has_any_role?(:owner, :admin, :member, record.account)
  end

  def update?
    user.has_any_role?(:owner, :admin, record.account) ||
      user.has_role?(:project_admin, record)
  end

  def destroy?
    user.has_any_role?(:owner, :admin, record.account)
  end

  def run_agent?
    user.has_any_role?(:owner, :admin, :member, record.account) ||
      user.has_any_role?(:project_admin, :project_member, record)
  end

  def interrupt_agent?
    run_agent?
  end

  private

  def user_in_account?
    user.account_id == record.account_id
  end

  def user_has_project_role?
    user.has_any_role?(:project_admin, :project_member, record)
  end
end

# app/policies/prompt_policy.rb
class PromptPolicy < ApplicationPolicy
  def update?
    # Only admins can modify prompts (they affect all agent runs)
    user.has_any_role?(:owner, :admin, account_for_record)
  end

  def create_ab_test?
    update?
  end

  private

  def account_for_record
    record.project&.account || record.account
  end
end
```

### Controller Integration

```ruby
# app/controllers/projects_controller.rb
class ProjectsController < ApplicationController
  before_action :set_project, only: [:show, :update, :destroy]

  def show
    authorize @project
    # ...
  end

  def create
    @project = current_account.projects.build(project_params)
    authorize @project
    # ...
  end

  private

  def set_project
    @project = current_account.projects.find(params[:id])
  end
end
```

### github_tokens

Encrypted storage for GitHub Personal Access Tokens. Tokens belong to the account (shared across team) but track who created them.

```sql
CREATE TABLE github_tokens (
  id              BIGSERIAL PRIMARY KEY,
  account_id      BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_by_id   BIGINT REFERENCES users(id) ON DELETE SET NULL,

  name            VARCHAR(255) NOT NULL,  -- User-friendly name
  encrypted_token TEXT NOT NULL,          -- Rails encrypted attribute
  scopes          JSONB NOT NULL,         -- Detected/claimed scopes
  expires_at      TIMESTAMP,              -- For fine-grained PATs
  last_used_at    TIMESTAMP,

  -- Status
  active          BOOLEAN DEFAULT TRUE,
  rotation_reminder_sent_at TIMESTAMP,

  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_github_tokens_account ON github_tokens(account_id);
CREATE INDEX idx_github_tokens_active ON github_tokens(account_id, active) WHERE active = TRUE;
```

### projects

GitHub repositories added to Paid. Projects belong to an account and are visible to all account members.

```sql
CREATE TABLE projects (
  id                    BIGSERIAL PRIMARY KEY,
  account_id            BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  github_token_id       BIGINT NOT NULL REFERENCES github_tokens(id),
  created_by_id         BIGINT REFERENCES users(id) ON DELETE SET NULL,

  -- GitHub identifiers
  github_repo_id        BIGINT NOT NULL,          -- GitHub's repo ID
  github_owner          VARCHAR(255) NOT NULL,    -- org or user
  github_repo           VARCHAR(255) NOT NULL,    -- repo name
  github_default_branch VARCHAR(255) DEFAULT 'main',

  -- Configuration
  name                  VARCHAR(255) NOT NULL,    -- Display name
  active                BOOLEAN DEFAULT TRUE,
  poll_interval_seconds INTEGER DEFAULT 60,

  -- GitHub Projects V2 integration
  github_project_id     BIGINT,                   -- GitHub Project ID if available
  projects_enabled      BOOLEAN DEFAULT FALSE,

  -- Label configuration (JSONB for flexibility)
  labels                JSONB DEFAULT '{
    "plan": "paid-plan",
    "build": "paid-build",
    "review": "paid-review",
    "needs_input": "paid-needs-input"
  }',

  -- Metrics cache
  total_cost_cents      INTEGER DEFAULT 0,
  total_tokens_used     BIGINT DEFAULT 0,

  created_at            TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_projects_github_repo ON projects(account_id, github_repo_id);
CREATE INDEX idx_projects_account ON projects(account_id);
CREATE INDEX idx_projects_active ON projects(account_id, active) WHERE active = TRUE;
```

### issues

Tracked GitHub issues (cached locally for performance).

```sql
CREATE TABLE issues (
  id                BIGSERIAL PRIMARY KEY,
  project_id        BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

  -- GitHub identifiers
  github_issue_id   BIGINT NOT NULL,
  github_number     INTEGER NOT NULL,

  -- Issue data (cached)
  title             VARCHAR(1000) NOT NULL,
  body              TEXT,
  state             VARCHAR(50) NOT NULL,     -- open, closed
  labels            JSONB DEFAULT '[]',

  -- Paid state
  paid_state        VARCHAR(50) DEFAULT 'new', -- new, planning, in_progress, completed, failed
  parent_issue_id   BIGINT REFERENCES issues(id), -- For sub-issues

  -- Timestamps
  github_created_at TIMESTAMP,
  github_updated_at TIMESTAMP,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_issues_github ON issues(project_id, github_issue_id);
CREATE INDEX idx_issues_project_state ON issues(project_id, paid_state);
CREATE INDEX idx_issues_parent ON issues(parent_issue_id);
```

### agent_runs

Individual agent execution records.

```sql
CREATE TABLE agent_runs (
  id                  BIGSERIAL PRIMARY KEY,
  project_id          BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  issue_id            BIGINT REFERENCES issues(id),
  prompt_version_id   BIGINT REFERENCES prompt_versions(id),
  model_id            BIGINT REFERENCES models(id),

  -- Temporal tracking
  temporal_workflow_id  VARCHAR(255),
  temporal_run_id       VARCHAR(255),

  -- Agent configuration
  agent_type          VARCHAR(50) NOT NULL,   -- claude_code, cursor, codex, copilot, api

  -- Execution state
  status              VARCHAR(50) NOT NULL DEFAULT 'pending',
  -- pending, running, completed, failed, cancelled, timeout

  -- Git context
  worktree_path       VARCHAR(500),
  branch_name         VARCHAR(255),
  base_commit_sha     VARCHAR(40),
  result_commit_sha   VARCHAR(40),

  -- Results
  pull_request_url    VARCHAR(500),
  pull_request_number INTEGER,
  error_message       TEXT,

  -- Metrics
  iterations          INTEGER DEFAULT 0,
  duration_seconds    INTEGER,
  tokens_input        INTEGER DEFAULT 0,
  tokens_output       INTEGER DEFAULT 0,
  cost_cents          INTEGER DEFAULT 0,

  -- Timestamps
  started_at          TIMESTAMP,
  completed_at        TIMESTAMP,
  created_at          TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agent_runs_project ON agent_runs(project_id);
CREATE INDEX idx_agent_runs_issue ON agent_runs(issue_id);
CREATE INDEX idx_agent_runs_status ON agent_runs(status);
CREATE INDEX idx_agent_runs_temporal ON agent_runs(temporal_workflow_id);
```

### agent_run_logs

Detailed logs from agent execution (stored separately for size).

```sql
CREATE TABLE agent_run_logs (
  id            BIGSERIAL PRIMARY KEY,
  agent_run_id  BIGINT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,

  log_type      VARCHAR(50) NOT NULL,  -- stdout, stderr, system, metric
  content       TEXT NOT NULL,
  metadata      JSONB,

  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_agent_run_logs_run ON agent_run_logs(agent_run_id);
CREATE INDEX idx_agent_run_logs_type ON agent_run_logs(agent_run_id, log_type);
```

---

## Prompt System

### prompts

Named prompt templates that can be versioned.

```sql
CREATE TABLE prompts (
  id            BIGSERIAL PRIMARY KEY,

  -- Identification
  slug          VARCHAR(100) NOT NULL UNIQUE,  -- e.g., "planning.feature_decomposition"
  name          VARCHAR(255) NOT NULL,
  description   TEXT,
  category      VARCHAR(50) NOT NULL,          -- planning, coding, review, evolution

  -- Scope
  project_id    BIGINT REFERENCES projects(id), -- NULL = global

  -- Current version pointer
  current_version_id BIGINT,  -- Set after version created

  -- Status
  active        BOOLEAN DEFAULT TRUE,

  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_prompts_slug ON prompts(slug);
CREATE INDEX idx_prompts_category ON prompts(category);
CREATE INDEX idx_prompts_project ON prompts(project_id);
```

### prompt_versions

Immutable versions of prompts.

```sql
CREATE TABLE prompt_versions (
  id            BIGSERIAL PRIMARY KEY,
  prompt_id     BIGINT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,

  -- Version number (auto-incremented per prompt)
  version       INTEGER NOT NULL,

  -- Content
  template      TEXT NOT NULL,                -- The actual prompt template
  variables     JSONB DEFAULT '[]',           -- Expected variables
  system_prompt TEXT,                         -- Optional system prompt

  -- Metadata
  change_notes  TEXT,
  created_by    VARCHAR(50),                  -- 'user', 'evolution', 'ab_test'
  parent_version_id BIGINT REFERENCES prompt_versions(id), -- Lineage tracking

  -- Performance (aggregated)
  usage_count   INTEGER DEFAULT 0,
  avg_quality_score DECIMAL(4,2),
  avg_iterations DECIMAL(4,2),

  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_prompt_versions_unique ON prompt_versions(prompt_id, version);
CREATE INDEX idx_prompt_versions_prompt ON prompt_versions(prompt_id);
CREATE INDEX idx_prompt_versions_parent ON prompt_versions(parent_version_id);

-- Add foreign key after table exists
ALTER TABLE prompts
  ADD CONSTRAINT fk_prompts_current_version
  FOREIGN KEY (current_version_id)
  REFERENCES prompt_versions(id);
```

### quality_metrics

Quality measurements for agent runs (linked to prompt versions for analysis).

```sql
CREATE TABLE quality_metrics (
  id                BIGSERIAL PRIMARY KEY,
  agent_run_id      BIGINT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
  prompt_version_id BIGINT REFERENCES prompt_versions(id),

  -- Automated metrics
  iterations_to_complete INTEGER,
  ci_passed              BOOLEAN,
  lint_errors            INTEGER,
  test_failures          INTEGER,
  code_complexity_delta  DECIMAL(6,2),
  lines_changed          INTEGER,

  -- Human feedback
  human_vote             INTEGER,              -- -1, 0, 1 (down, none, up)
  human_feedback_source  VARCHAR(50),          -- github_pr, github_issue, ui
  human_feedback_at      TIMESTAMP,

  -- PR outcome
  pr_merged              BOOLEAN,
  pr_merged_at           TIMESTAMP,
  pr_changes_requested   BOOLEAN,

  -- Composite score (calculated)
  quality_score          DECIMAL(4,2),         -- 0.00 to 1.00

  created_at             TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_quality_metrics_run ON quality_metrics(agent_run_id);
CREATE INDEX idx_quality_metrics_prompt ON quality_metrics(prompt_version_id);
CREATE INDEX idx_quality_metrics_score ON quality_metrics(quality_score);
```

---

## A/B Testing System

### ab_tests

A/B test definitions.

```sql
CREATE TABLE ab_tests (
  id            BIGSERIAL PRIMARY KEY,
  prompt_id     BIGINT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,

  name          VARCHAR(255) NOT NULL,
  description   TEXT,

  -- Status
  status        VARCHAR(50) DEFAULT 'draft',  -- draft, running, paused, completed

  -- Configuration
  traffic_percentage INTEGER DEFAULT 100,     -- % of eligible runs to include
  min_sample_size    INTEGER DEFAULT 30,      -- Minimum runs per variant

  -- Results
  winner_variant_id  BIGINT,                  -- Set when test concludes
  confidence_level   DECIMAL(4,2),            -- Statistical confidence

  started_at    TIMESTAMP,
  completed_at  TIMESTAMP,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ab_tests_prompt ON ab_tests(prompt_id);
CREATE INDEX idx_ab_tests_status ON ab_tests(status);
```

### ab_test_variants

Variants in an A/B test.

```sql
CREATE TABLE ab_test_variants (
  id                BIGSERIAL PRIMARY KEY,
  ab_test_id        BIGINT NOT NULL REFERENCES ab_tests(id) ON DELETE CASCADE,
  prompt_version_id BIGINT NOT NULL REFERENCES prompt_versions(id),

  name              VARCHAR(100) NOT NULL,    -- 'control', 'variant_a', etc.
  weight            INTEGER DEFAULT 50,       -- Traffic weight (relative)

  -- Results (aggregated)
  sample_count      INTEGER DEFAULT 0,
  avg_quality_score DECIMAL(4,2),
  avg_iterations    DECIMAL(4,2),
  avg_cost_cents    DECIMAL(8,2),

  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ab_test_variants_test ON ab_test_variants(ab_test_id);
CREATE INDEX idx_ab_test_variants_prompt ON ab_test_variants(prompt_version_id);

-- Add foreign key for winner
ALTER TABLE ab_tests
  ADD CONSTRAINT fk_ab_tests_winner
  FOREIGN KEY (winner_variant_id)
  REFERENCES ab_test_variants(id);
```

### ab_test_assignments

Track which variant was used for each run.

```sql
CREATE TABLE ab_test_assignments (
  id              BIGSERIAL PRIMARY KEY,
  ab_test_id      BIGINT NOT NULL REFERENCES ab_tests(id) ON DELETE CASCADE,
  variant_id      BIGINT NOT NULL REFERENCES ab_test_variants(id),
  agent_run_id    BIGINT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,

  created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_ab_assignments_run ON ab_test_assignments(agent_run_id);
CREATE INDEX idx_ab_assignments_test ON ab_test_assignments(ab_test_id);
CREATE INDEX idx_ab_assignments_variant ON ab_test_assignments(variant_id);
```

---

## Model System

### models

Known LLM models (synced from ruby-llm registry).

```sql
CREATE TABLE models (
  id                  BIGSERIAL PRIMARY KEY,

  -- Identification
  provider            VARCHAR(50) NOT NULL,     -- anthropic, openai, google, etc.
  model_id            VARCHAR(100) NOT NULL,    -- claude-3-opus, gpt-4, etc.
  display_name        VARCHAR(255) NOT NULL,

  -- Capabilities (from ruby-llm)
  context_window      INTEGER,
  max_output_tokens   INTEGER,
  supports_vision     BOOLEAN DEFAULT FALSE,
  supports_tools      BOOLEAN DEFAULT FALSE,

  -- Costs (cents per 1K tokens)
  input_cost_per_1k   DECIMAL(8,4),
  output_cost_per_1k  DECIMAL(8,4),

  -- Status
  active              BOOLEAN DEFAULT TRUE,
  deprecated          BOOLEAN DEFAULT FALSE,

  -- Sync tracking
  registry_updated_at TIMESTAMP,

  created_at          TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_models_provider_id ON models(provider, model_id);
CREATE INDEX idx_models_active ON models(active) WHERE active = TRUE;
```

### model_selections

Log of model selection decisions (for analysis).

```sql
CREATE TABLE model_selections (
  id              BIGSERIAL PRIMARY KEY,
  agent_run_id    BIGINT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
  selected_model_id BIGINT NOT NULL REFERENCES models(id),

  -- Selection context
  selector_type   VARCHAR(50) NOT NULL,       -- meta_agent, rules, override

  -- Meta-agent reasoning (if applicable)
  reasoning       TEXT,

  -- Candidates considered
  candidates      JSONB,                      -- [{model_id, score, reason}]

  -- Constraints applied
  budget_limit_cents INTEGER,
  complexity_score   DECIMAL(4,2),

  created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_model_selections_run ON model_selections(agent_run_id);
CREATE INDEX idx_model_selections_model ON model_selections(selected_model_id);
```

### model_overrides

Per-project model preferences/restrictions.

```sql
CREATE TABLE model_overrides (
  id            BIGSERIAL PRIMARY KEY,
  project_id    BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

  -- Override type
  override_type VARCHAR(50) NOT NULL,         -- prefer, require, exclude
  model_id      BIGINT REFERENCES models(id),
  provider      VARCHAR(50),                  -- Or entire provider

  -- Scope
  task_category VARCHAR(50),                  -- planning, coding, review, or NULL for all

  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_model_overrides_project ON model_overrides(project_id);
```

---

## Style Guide System

### style_guides

LLM-friendly coding style guides.

```sql
CREATE TABLE style_guides (
  id            BIGSERIAL PRIMARY KEY,

  -- Scope
  project_id    BIGINT REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global

  name          VARCHAR(255) NOT NULL,

  -- Content
  raw_content   TEXT,                         -- User-edited content
  compressed    TEXT,                         -- LLM-optimized version

  -- Metadata
  language      VARCHAR(50),                  -- ruby, javascript, etc.
  framework     VARCHAR(50),                  -- rails, react, etc.

  -- Auto-extraction
  auto_extracted     BOOLEAN DEFAULT FALSE,
  extraction_source  VARCHAR(255),            -- e.g., "tree-sitter analysis"

  active        BOOLEAN DEFAULT TRUE,

  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_style_guides_project ON style_guides(project_id);
CREATE INDEX idx_style_guides_global ON style_guides(project_id) WHERE project_id IS NULL;
```

---

## Token Usage & Costs

### token_usages

Granular token usage tracking.

```sql
CREATE TABLE token_usages (
  id            BIGSERIAL PRIMARY KEY,
  agent_run_id  BIGINT REFERENCES agent_runs(id) ON DELETE CASCADE,
  project_id    BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  model_id      BIGINT NOT NULL REFERENCES models(id),

  -- Usage
  tokens_input  INTEGER NOT NULL,
  tokens_output INTEGER NOT NULL,

  -- Calculated cost (in cents)
  cost_cents    INTEGER NOT NULL,

  -- Context
  request_type  VARCHAR(50),                  -- agent_run, model_selection, etc.

  created_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_token_usages_project ON token_usages(project_id);
CREATE INDEX idx_token_usages_run ON token_usages(agent_run_id);
CREATE INDEX idx_token_usages_created ON token_usages(created_at);

-- Partition by month for performance (optional, implement when needed)
-- CREATE TABLE token_usages_2024_01 PARTITION OF token_usages
--   FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
```

### cost_budgets

Per-project cost limits.

```sql
CREATE TABLE cost_budgets (
  id                  BIGSERIAL PRIMARY KEY,
  project_id          BIGINT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

  -- Limits
  daily_limit_cents   INTEGER,
  monthly_limit_cents INTEGER,
  per_run_limit_cents INTEGER,

  -- Alerts
  alert_threshold_pct INTEGER DEFAULT 80,     -- Alert at 80% of limit

  -- Current period usage (updated by background job)
  current_daily_cents   INTEGER DEFAULT 0,
  current_monthly_cents INTEGER DEFAULT 0,

  created_at          TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_cost_budgets_project ON cost_budgets(project_id);
```

---

## Temporal Integration

### workflow_states

Track Temporal workflow states for UI display.

```sql
CREATE TABLE workflow_states (
  id                    BIGSERIAL PRIMARY KEY,

  -- Temporal identifiers
  temporal_workflow_id  VARCHAR(255) NOT NULL,
  temporal_run_id       VARCHAR(255),

  -- Paid context
  project_id            BIGINT REFERENCES projects(id) ON DELETE CASCADE,
  workflow_type         VARCHAR(100) NOT NULL,  -- GitHubPoll, AgentExecution, etc.

  -- State
  status                VARCHAR(50) NOT NULL,   -- running, completed, failed, cancelled

  -- Metadata
  input_data            JSONB,
  result_data           JSONB,
  error_message         TEXT,

  started_at            TIMESTAMP,
  completed_at          TIMESTAMP,
  created_at            TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_workflow_states_temporal ON workflow_states(temporal_workflow_id);
CREATE INDEX idx_workflow_states_project ON workflow_states(project_id);
CREATE INDEX idx_workflow_states_status ON workflow_states(status);
```

---

## Multi-Tenancy Architecture

Paid uses an **Account-based multi-tenancy** model where all resources belong to an account. This is implemented from day one to ensure clean data separation.

### Data Isolation Strategy

All tenant-scoped queries go through the account:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_current_account

  def current_account
    Current.account
  end

  private

  def set_current_account
    Current.account = current_user&.account
  end
end

# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account, :user, :trace_id
end
```

### Scoped Queries

Always scope queries to the current account:

```ruby
# GOOD: Scoped to account
current_account.projects.find(params[:id])
current_account.github_tokens.active

# BAD: Global query (security risk)
Project.find(params[:id])
```

### Account Hierarchy

```
Account
├── Users
│   └── AccountMemberships (role: viewer|member|admin|owner)
├── GitHub Tokens
├── Projects
│   ├── ProjectMemberships (role: viewer|member|admin)
│   ├── Issues
│   ├── Agent Runs
│   ├── Style Guides (project-specific)
│   └── Prompts (project-specific)
├── Style Guides (account-wide)
├── Prompts (account-wide)
└── Cost Budgets
```

### Future: Full Multi-Tenancy

For SaaS deployment, additional considerations:

| Concern | Current (Single-Team) | Future (Multi-Tenant) |
|---------|----------------------|----------------------|
| Data isolation | Account scoping | Row-level security or schema per account |
| Secrets | Shared encryption key | Per-account encryption keys |
| Temporal | Shared namespace | Per-account namespaces |
| Containers | Shared Docker host | Account-specific resource quotas |
| Billing | Per-project tracking | Per-account billing integration |

---

## Indexes Summary

Performance-critical indexes are defined inline above. Additional indexes to consider:

```sql
-- Time-series queries
CREATE INDEX idx_agent_runs_created ON agent_runs(created_at);
CREATE INDEX idx_token_usages_project_created ON token_usages(project_id, created_at);

-- Dashboard queries
CREATE INDEX idx_agent_runs_project_status ON agent_runs(project_id, status);

-- Quality analysis
CREATE INDEX idx_quality_metrics_prompt_created ON quality_metrics(prompt_version_id, created_at);
```

---

## Data Retention

Consider implementing data retention policies:

| Table | Retention | Rationale |
|-------|-----------|-----------|
| agent_run_logs | 90 days | Large, detailed logs |
| token_usages | 1 year | Cost analysis needs history |
| quality_metrics | Indefinite | Valuable for prompt evolution |
| ab_test_assignments | Until test completion + 30 days | Analysis only |
| workflow_states | 30 days | Operational data |

Implement via `pg_partman` or application-level cleanup jobs.

---

## Migration Strategy

Rails migrations should be created in order:

1. Accounts (tenant foundation)
2. Users (authentication, belongs to account)
3. AccountMemberships, ProjectMemberships (RBAC)
4. GithubTokens (belongs to account)
5. Projects, Issues (GitHub integration)
6. Prompts, PromptVersions (prompt system foundation)
7. Models, StyleGuides (configuration)
8. AgentRuns, AgentRunLogs (execution)
9. TokenUsages, CostBudgets (cost tracking)
10. QualityMetrics (quality tracking)
11. ABTests, ABTestVariants, ABTestAssignments (A/B testing)
12. ModelSelections, ModelOverrides (model system)
13. WorkflowStates (Temporal integration)

### Membership Setup

The membership tables are created via standard Rails migrations:

```ruby
# db/migrate/xxx_create_account_memberships.rb
create_table :account_memberships do |t|
  t.references :user, null: false, foreign_key: true
  t.references :account, null: false, foreign_key: true
  t.integer :role, null: false, default: 0
  t.timestamps
end
add_index :account_memberships, [:user_id, :account_id], unique: true

# db/migrate/xxx_create_project_memberships.rb
create_table :project_memberships do |t|
  t.references :user, null: false, foreign_key: true
  t.references :project, null: false, foreign_key: true
  t.integer :role, null: false, default: 0
  t.timestamps
end
add_index :project_memberships, [:user_id, :project_id], unique: true
```

The User model provides a compatible API with the same methods (`add_role`, `has_role?`, `has_any_role?`) that work transparently with the new membership tables.
