# frozen_string_literal: true

class DropLegacyProviderRenameColumns < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      remove_reference :agent_runs, :provider, foreign_key: { to_table: :runners }, index: true
      remove_column :agent_runs, :provider_switches, :integer
      remove_column :agent_runs, :providers_attempted, :jsonb
      remove_column :agent_runs, :final_provider, :string

      remove_reference :chat_sessions, :provider, foreign_key: { to_table: :runners }, index: true

      remove_column :user_settings, :default_agent_provider, :string
      remove_column :user_settings, :default_agent_providers_by_goal, :jsonb
      remove_column :user_settings, :fallback_providers, :jsonb
      remove_column :user_settings, :provider_selection_mode, :string
      remove_column :user_settings, :provider_round_robin_state, :jsonb
      remove_column :user_settings, :kb_chat_provider, :string
      remove_column :user_settings, :kb_chat_fallback_providers, :jsonb
      remove_column :user_settings, :kb_embedding_provider, :string
      remove_column :user_settings, :kb_embedding_fallback_providers, :jsonb

      remove_column :tenant_settings, :provider_preferences, :jsonb
      remove_column :tenant_settings, :allowed_provider_keys, :text, array: true

      remove_column :runner_states, :provider_name, :string
    end
  end
end
