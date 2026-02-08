# frozen_string_literal: true

# Replaces Rolify's polymorphic roles system with explicit membership tables.
#
# This migration provides equivalent RBAC functionality with several benefits:
# - Type-safe enums instead of string role names
# - Simpler queries without polymorphic lookups
# - Better Ruby 3.4 compatibility (no circular require issues)
# - Explicit foreign keys for referential integrity
#
# See docs/DATA_MODEL.md for the full authorization documentation.
class ReplaceRolifyWithMemberships < ActiveRecord::Migration[8.1]
  def up
    # Create account_memberships table
    create_table :account_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.integer :role, null: false, default: 0

      t.timestamps
    end

    add_index :account_memberships, [ :user_id, :account_id ], unique: true
    add_index :account_memberships, [ :account_id, :role ]

    # Create project_memberships table
    create_table :project_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.integer :role, null: false, default: 0

      t.timestamps
    end

    add_index :project_memberships, [ :user_id, :project_id ], unique: true
    add_index :project_memberships, [ :project_id, :role ]

    # Migrate existing rolify data to new tables
    migrate_existing_roles

    # Drop old rolify tables
    drop_table :users_roles
    drop_table :roles
  end

  def down
    # Recreate rolify tables
    create_table :roles do |t|
      t.string :name
      t.references :resource, polymorphic: true

      t.timestamps
    end

    add_index :roles, [ :name, :resource_type, :resource_id ], unique: true

    create_table :users_roles, id: false do |t|
      t.references :user, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
    end

    add_index :users_roles, [ :user_id, :role_id ], unique: true

    # Migrate data back to rolify format
    migrate_memberships_to_roles

    # Drop membership tables
    drop_table :project_memberships
    drop_table :account_memberships
  end

  private

  # Role enum values matching the AccountMembership model
  ACCOUNT_ROLES = { "viewer" => 0, "member" => 1, "admin" => 2, "owner" => 3 }.freeze

  # Role enum values matching the ProjectMembership model
  PROJECT_ROLES = { "viewer" => 0, "member" => 1, "admin" => 2 }.freeze

  def migrate_existing_roles
    # Migrate account-scoped roles
    execute <<~SQL
      INSERT INTO account_memberships (user_id, account_id, role, created_at, updated_at)
      SELECT DISTINCT
        ur.user_id,
        r.resource_id,
        CASE r.name
          WHEN 'owner' THEN 3
          WHEN 'admin' THEN 2
          WHEN 'member' THEN 1
          WHEN 'viewer' THEN 0
          ELSE 0
        END,
        NOW(),
        NOW()
      FROM users_roles ur
      JOIN roles r ON r.id = ur.role_id
      WHERE r.resource_type = 'Account'
      ON CONFLICT (user_id, account_id) DO UPDATE SET
        role = GREATEST(account_memberships.role, EXCLUDED.role)
    SQL

    # Migrate project-scoped roles
    execute <<~SQL
      INSERT INTO project_memberships (user_id, project_id, role, created_at, updated_at)
      SELECT DISTINCT
        ur.user_id,
        r.resource_id,
        CASE r.name
          WHEN 'project_admin' THEN 2
          WHEN 'project_member' THEN 1
          WHEN 'project_viewer' THEN 0
          ELSE 0
        END,
        NOW(),
        NOW()
      FROM users_roles ur
      JOIN roles r ON r.id = ur.role_id
      WHERE r.resource_type = 'Project'
      ON CONFLICT (user_id, project_id) DO UPDATE SET
        role = GREATEST(project_memberships.role, EXCLUDED.role)
    SQL
  end

  def migrate_memberships_to_roles
    # Migrate account memberships back to roles
    execute <<~SQL
      INSERT INTO roles (name, resource_type, resource_id, created_at, updated_at)
      SELECT DISTINCT
        CASE role
          WHEN 3 THEN 'owner'
          WHEN 2 THEN 'admin'
          WHEN 1 THEN 'member'
          WHEN 0 THEN 'viewer'
        END,
        'Account',
        account_id,
        NOW(),
        NOW()
      FROM account_memberships
    SQL

    execute <<~SQL
      INSERT INTO users_roles (user_id, role_id)
      SELECT am.user_id, r.id
      FROM account_memberships am
      JOIN roles r ON r.resource_type = 'Account'
        AND r.resource_id = am.account_id
        AND r.name = CASE am.role
          WHEN 3 THEN 'owner'
          WHEN 2 THEN 'admin'
          WHEN 1 THEN 'member'
          WHEN 0 THEN 'viewer'
        END
    SQL

    # Migrate project memberships back to roles
    execute <<~SQL
      INSERT INTO roles (name, resource_type, resource_id, created_at, updated_at)
      SELECT DISTINCT
        CASE role
          WHEN 2 THEN 'project_admin'
          WHEN 1 THEN 'project_member'
          WHEN 0 THEN 'project_viewer'
        END,
        'Project',
        project_id,
        NOW(),
        NOW()
      FROM project_memberships
    SQL

    execute <<~SQL
      INSERT INTO users_roles (user_id, role_id)
      SELECT pm.user_id, r.id
      FROM project_memberships pm
      JOIN roles r ON r.resource_type = 'Project'
        AND r.resource_id = pm.project_id
        AND r.name = CASE pm.role
          WHEN 2 THEN 'project_admin'
          WHEN 1 THEN 'project_member'
          WHEN 0 THEN 'project_viewer'
        END
    SQL
  end
end
