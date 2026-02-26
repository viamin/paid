# frozen_string_literal: true

class CreateUserSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :user_settings do |t|
      t.bigint :user_id, null: false

      # Polling & Timing
      t.integer :default_poll_interval_seconds, default: 60, null: false
      t.integer :github_token_cache_ttl_minutes, default: 60, null: false
      t.integer :token_validation_stale_minutes, default: 2, null: false

      # Agent Execution
      t.integer :agent_timeout_seconds, default: 3600, null: false
      t.string :default_agent_provider, default: "claude", null: false

      # Container Resources
      t.bigint :container_memory_bytes, default: 4 * 1024 * 1024 * 1024, null: false
      t.integer :container_cpu_quota, default: 200_000, null: false
      t.integer :container_timeout_seconds, default: 1800, null: false

      # Project Defaults
      t.jsonb :default_allowed_github_usernames, default: [], null: false
      t.string :default_branch, default: "main", null: false
      t.boolean :default_project_active, default: true, null: false

      # Retry & Resilience (Advanced)
      t.integer :circuit_breaker_failure_threshold, default: 5, null: false
      t.integer :circuit_breaker_timeout_seconds, default: 300, null: false
      t.integer :retry_max_attempts, default: 3, null: false
      t.float :retry_base_delay, default: 1.0, null: false
      t.float :retry_max_delay, default: 60.0, null: false

      t.timestamps
    end

    add_index :user_settings, :user_id, unique: true
    add_foreign_key :user_settings, :users
  end
end
