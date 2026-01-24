# RDR-010: Multi-Tenancy and RBAC

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Authorization policy tests, account scoping tests

## Problem Statement

Paid needs to support multiple users with different permission levels:

1. **Data isolation**: Users should only see their team's projects
2. **Role-based access**: Different permissions for owners, admins, members
3. **Resource scoping**: All queries must be tenant-aware
4. **Future SaaS**: Architecture should support multi-tenant SaaS later

Requirements:
- Account-based data isolation
- Flexible role system (account and resource level)
- Policy-based authorization
- Clean scoping patterns in code
- Migration path to full multi-tenancy

## Context

### Background

Phase 1 of Paid is single-team, but the architecture should support future multi-tenancy without major refactoring. Key insight: if everything is account-scoped from day one, adding multiple accounts later is straightforward.

### Technical Environment

- Rails 8+ application
- PostgreSQL database
- Team size: 1-20 users initially
- Resources: projects, tokens, prompts, agent runs

## Research Findings

### Investigation Process

1. Evaluated multi-tenancy patterns (schema, row-level, application)
2. Compared authorization gems (Pundit, CanCanCan, ActionPolicy)
3. Reviewed role management options (Rolify, custom)
4. Designed account hierarchy
5. Analyzed query scoping approaches

### Key Discoveries

**Multi-Tenancy Patterns:**

| Pattern | Isolation | Complexity | Scale |
|---------|-----------|------------|-------|
| Shared tables (row-level) | Application | Low | High |
| Schema per tenant | Database | Medium | Medium |
| Database per tenant | Complete | High | Low-Medium |

For Paid Phase 1, **row-level isolation** with account_id foreign keys is simplest and sufficient.

**Rolify for Role Management:**

Rolify provides flexible role scoping:

```ruby
# Global roles
user.add_role(:admin)
user.has_role?(:admin)

# Resource-scoped roles
user.add_role(:owner, account)
user.add_role(:project_admin, project)
user.has_role?(:owner, account)
```

Database schema (auto-generated):
```sql
CREATE TABLE roles (
  id BIGSERIAL PRIMARY KEY,
  name VARCHAR NOT NULL,
  resource_type VARCHAR,  -- NULL for global, 'Account' for account-scoped
  resource_id BIGINT,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE users_roles (
  user_id BIGINT REFERENCES users(id),
  role_id BIGINT REFERENCES roles(id)
);
```

**Pundit for Authorization:**

Pundit provides clean policy classes:

```ruby
# app/policies/project_policy.rb
class ProjectPolicy < ApplicationPolicy
  def show?
    user_in_account? || user_has_project_role?
  end

  def update?
    user.has_any_role?(:owner, :admin, record.account) ||
      user.has_role?(:project_admin, record)
  end

  def destroy?
    user.has_any_role?(:owner, :admin, record.account)
  end

  class Scope < Scope
    def resolve
      if user.has_role?(:admin)
        scope.all
      else
        scope.where(account: user.account)
      end
    end
  end
end
```

**Account Scoping Pattern:**

All queries flow through the current account:

```ruby
# GOOD: Scoped to account
current_account.projects.find(params[:id])
current_account.prompts.active

# BAD: Global query (security risk!)
Project.find(params[:id])
```

**CurrentAttributes for Request Context:**

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :account, :user, :request_id
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_current_attributes

  private

  def set_current_attributes
    Current.user = current_user
    Current.account = current_user&.account
    Current.request_id = request.uuid
  end

  def current_account
    Current.account
  end
end
```

## Proposed Solution

### Approach

Implement **account-based multi-tenancy** with **Rolify** for role management and **Pundit** for authorization:

1. **Account model**: All resources belong to an account
2. **Rolify roles**: Flexible role assignment at account and resource level
3. **Pundit policies**: Authorization logic per resource type
4. **Scoped queries**: All data access through account context
5. **CurrentAttributes**: Request-scoped context

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MULTI-TENANCY ARCHITECTURE                              │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         ACCOUNT HIERARCHY                                ││
│  │                                                                          ││
│  │  Account                                                                 ││
│  │  ├── Users (with roles via Rolify)                                      ││
│  │  │   └── Roles: owner, admin, member, viewer                           ││
│  │  ├── GitHub Tokens                                                      ││
│  │  ├── Projects                                                           ││
│  │  │   ├── Issues                                                         ││
│  │  │   ├── Agent Runs                                                     ││
│  │  │   ├── Style Guides (project-specific)                               ││
│  │  │   └── Prompts (project-specific)                                    ││
│  │  ├── Style Guides (account-wide)                                       ││
│  │  ├── Prompts (account-wide)                                            ││
│  │  └── Cost Budgets                                                       ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         ROLE DEFINITIONS                                 ││
│  │                                                                          ││
│  │  Account-Level Roles:                                                   ││
│  │  ┌─────────┬────────────────────────────────────────────────────────┐  ││
│  │  │ owner   │ Full access, delete account, manage billing            │  ││
│  │  │ admin   │ Manage users, projects, settings (no delete account)   │  ││
│  │  │ member  │ Add projects, run agents, view all data                │  ││
│  │  │ viewer  │ Read-only access                                        │  ││
│  │  └─────────┴────────────────────────────────────────────────────────┘  ││
│  │                                                                          ││
│  │  Resource-Level Roles:                                                  ││
│  │  ┌───────────────┬──────────────────────────────────────────────────┐  ││
│  │  │ project_admin │ Full control over specific project               │  ││
│  │  │ project_member│ Run agents, view project data                    │  ││
│  │  └───────────────┴──────────────────────────────────────────────────┘  ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         AUTHORIZATION FLOW                               ││
│  │                                                                          ││
│  │  Request                                                                ││
│  │     │                                                                   ││
│  │     ▼                                                                   ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Authenticate│  Devise / custom auth                                 ││
│  │  │ User        │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                               ││
│  │         ▼                                                               ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Set Current │  Current.user, Current.account                        ││
│  │  │ Context     │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                               ││
│  │         ▼                                                               ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Scope Query │  current_account.projects.find(id)                    ││
│  │  │ to Account  │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                               ││
│  │         ▼                                                               ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Authorize   │  authorize @project  (Pundit)                         ││
│  │  │ Action      │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                               ││
│  │         ▼                                                               ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Execute     │  Action proceeds                                      ││
│  │  │ Action      │                                                        ││
│  │  └─────────────┘                                                        ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Account-based**: Natural grouping for teams, easy to extend to SaaS
2. **Rolify**: Flexible, well-maintained, handles complex role scoping
3. **Pundit**: Clean policy classes, integrates well with Rails
4. **Row-level isolation**: Simple, efficient, widely understood
5. **CurrentAttributes**: Rails-native request context

### Implementation Example

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  resourcify  # Rolify: allows roles to be scoped to accounts

  has_many :users, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :github_tokens, dependent: :destroy
  has_many :prompts, -> { where(project_id: nil) }  # Account-level prompts

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
end

# app/models/user.rb
class User < ApplicationRecord
  rolify

  belongs_to :account
  has_many :github_tokens, foreign_key: :created_by_id

  validates :email, presence: true, uniqueness: true
end

# app/models/project.rb
class Project < ApplicationRecord
  resourcify  # Allows project-level roles

  belongs_to :account
  belongs_to :github_token
  has_many :issues, dependent: :destroy
  has_many :agent_runs, dependent: :destroy

  validates :github_repo, presence: true
end

# app/policies/application_policy.rb
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    user_in_account?
  end

  def show?
    user_in_account?
  end

  def create?
    user.has_any_role?(:owner, :admin, :member, account_for_record)
  end

  def update?
    user.has_any_role?(:owner, :admin, account_for_record)
  end

  def destroy?
    user.has_any_role?(:owner, :admin, account_for_record)
  end

  private

  def user_in_account?
    user.account_id == account_for_record&.id
  end

  def account_for_record
    record.respond_to?(:account) ? record.account : record
  end
end

# app/policies/project_policy.rb
class ProjectPolicy < ApplicationPolicy
  def show?
    user_in_account? || user_has_project_role?
  end

  def run_agent?
    user.has_any_role?(:owner, :admin, :member, record.account) ||
      user.has_any_role?(:project_admin, :project_member, record)
  end

  def interrupt_agent?
    run_agent?
  end

  def update?
    user.has_any_role?(:owner, :admin, record.account) ||
      user.has_role?(:project_admin, record)
  end

  class Scope < Scope
    def resolve
      scope.where(account: user.account)
    end
  end

  private

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

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization

  before_action :authenticate_user!
  before_action :set_current_attributes

  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def set_current_attributes
    Current.user = current_user
    Current.account = current_user&.account
    Current.request_id = request.uuid
  end

  def current_account
    Current.account
  end

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back(fallback_location: root_path)
  end
end

# app/controllers/projects_controller.rb
class ProjectsController < ApplicationController
  def index
    @projects = policy_scope(current_account.projects)
  end

  def show
    @project = current_account.projects.find(params[:id])
    authorize @project
  end

  def create
    @project = current_account.projects.build(project_params)
    authorize @project

    if @project.save
      redirect_to @project, notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @project = current_account.projects.find(params[:id])
    authorize @project

    if @project.update(project_params)
      redirect_to @project, notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project = current_account.projects.find(params[:id])
    authorize @project

    @project.destroy
    redirect_to projects_path, notice: "Project deleted."
  end

  private

  def project_params
    params.require(:project).permit(:name, :github_token_id, :github_repo)
  end
end
```

## Alternatives Considered

### Alternative 1: CanCanCan

**Description**: Use CanCanCan instead of Pundit for authorization

**Pros**:
- Single Ability class
- Well-known in Rails community
- Good documentation

**Cons**:
- Single file can become unwieldy
- Less explicit than Pundit policies
- Harder to test in isolation

**Reason for rejection**: Pundit's policy-per-resource pattern is cleaner for complex authorization rules.

### Alternative 2: Custom Role System

**Description**: Build role management from scratch

**Pros**:
- Full control
- No gem dependencies
- Tailored to needs

**Cons**:
- Development time
- Maintenance burden
- Rolify solves this well

**Reason for rejection**: Rolify is battle-tested and handles complex role scoping we need.

### Alternative 3: ActionPolicy

**Description**: Use ActionPolicy gem instead of Pundit

**Pros**:
- More features (caching, scoping)
- Good performance
- Active development

**Cons**:
- Smaller community
- More complex
- Less documentation

**Reason for rejection**: Pundit is simpler and sufficient for current needs. ActionPolicy is good but adds complexity we don't need.

### Alternative 4: Schema-Per-Tenant

**Description**: Use PostgreSQL schemas for tenant isolation

**Pros**:
- Database-level isolation
- Clear separation
- Can have different schemas per tenant

**Cons**:
- Migration complexity (must run per-schema)
- Connection management complexity
- Harder to query across tenants

**Reason for rejection**: Overkill for Phase 1. Row-level isolation is simpler and sufficient.

## Trade-offs and Consequences

### Positive Consequences

- **Clean authorization**: Explicit policies per resource
- **Flexible roles**: Account-level and resource-level roles
- **Future-proof**: Architecture supports SaaS migration
- **Testable**: Policies easily unit tested
- **Rails-native**: Uses Rails patterns and conventions

### Negative Consequences

- **Query discipline**: Must always scope to account
- **Policy maintenance**: Policy per resource type
- **Performance**: Role checks add overhead (minimal)

### Risks and Mitigations

- **Risk**: Developers forget account scoping
  **Mitigation**: Linting rules, code review, integration tests. Consider default scope on models (with care).

- **Risk**: Role hierarchy becomes complex
  **Mitigation**: Keep roles simple initially. Document role meanings clearly.

- **Risk**: Cross-account data leak
  **Mitigation**: Test coverage for authorization. Regular security audits.

## Implementation Plan

### Prerequisites

- [ ] Rolify and Pundit gems added
- [ ] Devise or authentication system in place
- [ ] Account model created

### Step-by-Step Implementation

#### Step 1: Add Gems

```ruby
# Gemfile
gem "rolify"
gem "pundit"
```

#### Step 2: Generate Rolify

```bash
rails generate rolify Role User
rails db:migrate
```

#### Step 3: Generate Pundit

```bash
rails generate pundit:install
```

#### Step 4: Create Account Model

```ruby
# db/migrate/xxx_create_accounts.rb
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.jsonb :settings, default: {}
      t.string :plan, default: 'free'

      t.timestamps
    end

    add_index :accounts, :slug, unique: true
  end
end
```

#### Step 5: Add Account Reference to Users

```ruby
# db/migrate/xxx_add_account_to_users.rb
class AddAccountToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :account, null: false, foreign_key: true
  end
end
```

#### Step 6: Create Policies

Create policy files for each resource as shown above.

#### Step 7: Update Controllers

Add authorization checks to all controllers.

### Files to Create/Modify

- `Gemfile` - Add rolify, pundit
- `db/migrate/xxx_create_accounts.rb`
- `db/migrate/xxx_add_account_to_users.rb`
- `app/models/account.rb`
- `app/models/user.rb` - Add rolify
- `app/models/current.rb`
- `app/policies/application_policy.rb`
- `app/policies/*_policy.rb` - Per-resource policies
- `app/controllers/application_controller.rb`
- All controllers - Add authorization

### Dependencies

- `rolify` (~> 6.0)
- `pundit` (~> 2.0)

## Validation

### Testing Approach

1. Policy unit tests for each policy class
2. Controller tests for authorization enforcement
3. Integration tests for role-based access
4. Security tests for cross-account isolation

### Test Scenarios

1. **Scenario**: User views project in their account
   **Expected Result**: Access granted

2. **Scenario**: User views project in different account
   **Expected Result**: RecordNotFound (scoped query)

3. **Scenario**: Member tries to delete project
   **Expected Result**: Pundit::NotAuthorizedError

4. **Scenario**: Project admin updates their project
   **Expected Result**: Access granted

### Performance Validation

- Role checks < 5ms
- Policy evaluations < 1ms
- No N+1 queries from role checks

### Security Validation

- No cross-account data access possible
- All controllers have authorization
- Policy tests have full coverage

## References

### Requirements & Standards

- Paid DATA_MODEL.md - Account model design
- [OWASP Access Control](https://owasp.org/www-community/Access_Control)

### Dependencies

- [Rolify](https://github.com/RolifyCommunity/rolify)
- [Pundit](https://github.com/varvet/pundit)

### Research Resources

- Multi-tenancy patterns in Rails
- Row-level security in PostgreSQL
- Authorization best practices

## Notes

- Consider adding audit logging for authorization decisions
- Plan for role hierarchy (owner > admin > member > viewer) if needed
- Future: PostgreSQL Row-Level Security for defense-in-depth
- Monitor for authorization bypasses in security reviews
