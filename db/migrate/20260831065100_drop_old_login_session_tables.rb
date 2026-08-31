# frozen_string_literal: true

class DropOldLoginSessionTables < ActiveRecord::Migration[8.1]
  def change
    drop_table :claude_login_sessions, if_exists: true
    drop_table :codex_login_sessions, if_exists: true
  end
end
