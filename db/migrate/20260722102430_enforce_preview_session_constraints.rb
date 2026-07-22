# frozen_string_literal: true

class EnforcePreviewSessionConstraints < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      change_column_null :preview_sessions, :branch_name, false
      change_column_null :preview_sessions, :expires_at, false
      change_column_null :preview_sessions, :account_id, false

      unless foreign_key_exists?(:preview_sessions, :accounts)
        add_foreign_key :preview_sessions, :accounts, on_delete: :cascade
      end

      unless foreign_key_exists?(:preview_sessions, :users, column: :created_by_id)
        add_foreign_key :preview_sessions, :users, column: :created_by_id, on_delete: :nullify
      end

      execute <<~SQL
        ALTER TABLE preview_sessions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE preview_sessions FORCE ROW LEVEL SECURITY;
        DROP POLICY IF EXISTS tenant_isolation ON preview_sessions;
        CREATE POLICY tenant_isolation ON preview_sessions
          USING (
            paid_tenant_bypass() OR preview_sessions.account_id = paid_current_account_id()
          )
          WITH CHECK (
            paid_tenant_bypass() OR preview_sessions.account_id = paid_current_account_id()
          );
      SQL
    end
  end

  def down
    safety_assured do
      if foreign_key_exists?(:preview_sessions, :users, column: :created_by_id)
        remove_foreign_key :preview_sessions, :users, column: :created_by_id
      end
      if foreign_key_exists?(:preview_sessions, :accounts)
        remove_foreign_key :preview_sessions, :accounts
      end
      change_column_null :preview_sessions, :account_id, true
      change_column_null :preview_sessions, :expires_at, true
      change_column_null :preview_sessions, :branch_name, true
    end
  end
end
