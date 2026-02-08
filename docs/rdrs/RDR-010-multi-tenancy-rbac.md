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
3. Reviewed role management options (Rolify, custom, explicit membership tables)
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

**Explicit Membership Tables for Role Management:**

Rather than using Rolify's polymorphic role system, Paid uses explicit join tables with Rails enums for type-safe role management:

```ruby
# Account-level roles via AccountMembership
user.add_role(:owner, account)
user.has_role?(:admin, account)

# Project-level roles via ProjectMembership
user.add_role(:admin, project)       # stored as ProjectMembership role: :admin
user.add_role(:project_admin, project) # legacy format also supported via normalization
```

Database schema:

```sql
CREATE TABLE account_memberships (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  account_id BIGINT NOT NULL REFERENCES accounts(id),
  role INTEGER NOT NULL DEFAULT 0,  -- enum: viewer(0), member(1), admin(2), owner(3)
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE project_memberships (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  project_id BIGINT NOT NULL REFERENCES projects(id),
  role INTEGER NOT NULL DEFAULT 0,  -- enum: viewer(0), member(1), admin(2)
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

This approach provides type-safe enums, simpler queries, and no external gem dependency while maintaining a compatible API (`has_role?`, `add_role`, etc.).

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
      if user.has_any_role?(:owner, :admin, record.account)
        scope.where(account: record.account)
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

Implement **account-based multi-tenancy** with **explicit membership tables** for role management and **Pundit** for authorization:

1. **Account model**: All resources belong to an account
2. **Membership tables**: Type-safe role assignment at account and project level via `AccountMembership` and `ProjectMembership`
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
│  │  ├── Users (with roles via membership tables)                            ││
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
│  │  │ Authenticate│  Devise                                                ││
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
2. **Membership tables**: Type-safe enums, no gem dependency, simpler queries than Rolify's polymorphic approach
3. **Pundit**: Clean policy classes, integrates well with Rails
4. **Row-level isolation**: Simple, efficient, widely understood
5. **CurrentAttributes**: Rails-native request context

### Implementation Example

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  has_many :account_memberships, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :github_tokens, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
end

# app/models/account_membership.rb
class AccountMembership < ApplicationRecord
  belongs_to :user
  belongs_to :account

  enum :role, { viewer: 0, member: 1, admin: 2, owner: 3 }, validate: true

  validates :user_id, uniqueness: { scope: :account_id }

  def at_least?(minimum_role)
    permission_level >= self.class.roles[minimum_role.to_s]
  end

  def permission_level
    self.class.roles[role]
  end
end

# app/models/project_membership.rb
class ProjectMembership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  enum :role, { viewer: 0, member: 1, admin: 2 }, validate: true

  validates :user_id, uniqueness: { scope: :project_id }

  def at_least?(minimum_role)
    permission_level >= self.class.roles[minimum_role.to_s]
  end

  def permission_level
    self.class.roles[role]
  end
end

# app/models/user.rb
class User < ApplicationRecord
  belongs_to :account
  has_many :account_memberships, dependent: :destroy
  has_many :project_memberships, dependent: :destroy

  after_create :assign_owner_role_if_first_user

  # Role management API (compatible with previous Rolify interface)
  def has_role?(role, resource)
    membership = membership_for(resource)
    return false unless membership
    normalize_role(role, resource) == membership.role
  end

  def has_any_role?(*args)
    resource = args.pop
    roles = args
    membership = membership_for(resource)
    return false unless membership
    roles.any? { |role| normalize_role(role, resource) == membership.role }
  end

  def add_role(role, resource)
    normalized_role = normalize_role(role, resource)
    case resource
    when Account
      account_memberships.find_or_initialize_by(account: resource).tap { |m| m.update!(role: normalized_role) }
    when Project
      project_memberships.find_or_initialize_by(project: resource).tap { |m| m.update!(role: normalized_role) }
    end
  end

  private

  def membership_for(resource)
    case resource
    when Account then account_memberships.find_by(account: resource)
    when Project then project_memberships.find_by(project: resource)
    end
  end

  def normalize_role(role, resource)
    role_str = role.to_s
    resource.is_a?(Project) ? role_str.sub(/^project_/, "") : role_str
  end

  def assign_owner_role_if_first_user
    # Ensure every user has at least a default member role in their account
    add_role(:member, account)

    # Promote the very first user in the account to owner
    add_role(:owner, account) if account.users.count == 1
  end
end

# app/models/project.rb
class Project < ApplicationRecord
  belongs_to :account
  belongs_to :github_token
  has_many :project_memberships, dependent: :destroy
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
    has_any_account_role?(:owner, :admin, :member)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  private

  def user_in_account?
    return false unless user
    has_any_account_role?(:owner, :admin, :member, :viewer)
  end

  def account_for_record
    record.respond_to?(:account) ? record.account : record
  end

  def has_account_role?(role)
    return false unless user
    user.has_role?(role, account_for_record)
  end

  def has_any_account_role?(*roles)
    return false unless user
    account = account_for_record
    roles.any? { |role| user.has_role?(role, account) }
  end
end

# app/policies/project_policy.rb
class ProjectPolicy < ApplicationPolicy
  def run_agent?
    return false unless user_in_account?
    has_any_account_role?(:owner, :admin, :member) || has_project_role?
  end

  private

  def has_project_role?
    return false unless user && record.is_a?(Project)
    user.has_any_role?(:project_admin, :project_member, record)
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

### Alternative 2: Rolify Gem

**Description**: Use the Rolify gem for polymorphic role management

**Pros**:

- Well-maintained, battle-tested gem
- Flexible polymorphic role scoping
- Large community

**Cons**:

- Polymorphic `roles` and `users_roles` tables add indirection
- String-based role names lack type safety
- Additional gem dependency
- Queries are more complex than direct enum lookups

**Reason for rejection**: Explicit membership tables with Rails enums provide type safety, simpler queries, and no external dependency. The compatible API (`has_role?`, `add_role`) preserves the same developer experience.

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
- **Type-safe roles**: Rails enums provide a constrained set of allowed role values with application-level validation
- **Flexible roles**: Account-level and project-level roles via dedicated membership tables
- **No external dependency**: Role management requires no additional gems
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
  **Mitigation**: Keep roles simple initially. Enum ordering provides natural hierarchy (higher value = more permissions).

- **Risk**: Cross-account data leak
  **Mitigation**: Test coverage for authorization. Regular security audits.

## Implementation Plan

### Prerequisites

- [ ] Pundit gem added
- [ ] Devise authentication in place
- [ ] Account model created

### Step-by-Step Implementation

#### Step 1: Add Gems

```ruby
# Gemfile
gem "pundit"
```

#### Step 2: Generate Pundit

```bash
rails generate pundit:install
```

#### Step 3: Create Account Model

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

#### Step 4: Add Account Reference to Users

```ruby
# db/migrate/xxx_add_account_to_users.rb
class AddAccountToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :account, null: false, foreign_key: true
  end
end
```

#### Step 5: Create Membership Tables

```ruby
# db/migrate/xxx_create_account_memberships.rb
class CreateAccountMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :account_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.integer :role, null: false, default: 0  # viewer(0), member(1), admin(2), owner(3)

      t.timestamps
    end

    add_index :account_memberships, [:user_id, :account_id], unique: true
  end
end

# db/migrate/xxx_create_project_memberships.rb
class CreateProjectMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :project_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.integer :role, null: false, default: 0  # viewer(0), member(1), admin(2)

      t.timestamps
    end

    add_index :project_memberships, [:user_id, :project_id], unique: true
  end
end
```

#### Step 6: Create Policies

Create policy files for each resource as shown above.

#### Step 7: Update Controllers

Add authorization checks to all controllers.

### Files to Create/Modify

- `Gemfile` - Add pundit
- `db/migrate/xxx_create_accounts.rb`
- `db/migrate/xxx_add_account_to_users.rb`
- `db/migrate/xxx_create_account_memberships.rb`
- `db/migrate/xxx_create_project_memberships.rb`
- `app/models/account.rb`
- `app/models/account_membership.rb`
- `app/models/project_membership.rb`
- `app/models/user.rb` - Add role management methods
- `app/models/current.rb`
- `app/policies/application_policy.rb`
- `app/policies/*_policy.rb` - Per-resource policies
- `app/controllers/application_controller.rb`
- All controllers - Add authorization

### Dependencies

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
