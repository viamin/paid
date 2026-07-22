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
