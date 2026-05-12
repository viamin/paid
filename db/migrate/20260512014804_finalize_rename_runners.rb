# frozen_string_literal: true

class FinalizeRenameRunners < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :agent_runs, name: "fk_rails_0af97c5d68"
    remove_foreign_key :chat_sessions, name: "fk_rails_b20daa8c1f"

    safety_assured do
      remove_column :agent_runs, :provider_id
      remove_column :agent_runs, :provider_switches
      remove_column :agent_runs, :providers_attempted
      remove_column :agent_runs, :final_provider

      remove_column :chat_sessions, :provider_id

      remove_column :user_settings, :default_agent_provider
      remove_column :user_settings, :default_agent_providers_by_goal
      remove_column :user_settings, :fallback_providers
      remove_column :user_settings, :provider_selection_mode
      remove_column :user_settings, :provider_round_robin_state
      remove_column :user_settings, :kb_chat_provider
      remove_column :user_settings, :kb_chat_fallback_providers
      remove_column :user_settings, :kb_embedding_provider
      remove_column :user_settings, :kb_embedding_fallback_providers

      remove_column :tenant_settings, :provider_preferences
      remove_column :tenant_settings, :allowed_provider_keys

      rename_table :providers, :runners
      rename_table :provider_states, :runner_states
    end
  end

  def down
    safety_assured do
      rename_table :runner_states, :provider_states
      rename_table :runners, :providers
    end

    add_column :tenant_settings, :allowed_provider_keys, :text, array: true, default: []
    add_column :tenant_settings, :provider_preferences, :jsonb, default: {}, null: false

    add_column :user_settings, :kb_embedding_fallback_providers, :jsonb, default: [], null: false
    add_column :user_settings, :kb_embedding_provider, :string, default: "openai", null: false
    add_column :user_settings, :kb_chat_fallback_providers, :jsonb, default: [], null: false
    add_column :user_settings, :kb_chat_provider, :string, default: "claude", null: false
    add_column :user_settings, :provider_round_robin_state, :jsonb, default: {}, null: false
    add_column :user_settings, :provider_selection_mode, :string, limit: 20, default: "single", null: false
    add_column :user_settings, :fallback_providers, :jsonb, default: [], null: false
    add_column :user_settings, :default_agent_providers_by_goal, :jsonb, default: {}, null: false
    add_column :user_settings, :default_agent_provider, :string, default: "claude", null: false

    add_column :chat_sessions, :provider_id, :bigint

    add_column :agent_runs, :final_provider, :string, limit: 50
    add_column :agent_runs, :providers_attempted, :jsonb, default: [], null: false
    add_column :agent_runs, :provider_switches, :integer, default: 0, null: false
    add_column :agent_runs, :provider_id, :bigint

    add_index :chat_sessions, :provider_id, name: "index_chat_sessions_on_provider_id"
    add_foreign_key :chat_sessions, :providers, on_delete: :nullify

    add_index :agent_runs, :provider_id, name: "index_agent_runs_on_provider_id"
    add_foreign_key :agent_runs, :providers, on_delete: :nullify
  end
end
