# frozen_string_literal: true

# Phase 1 of the providers→runners rename. Safe to deploy alongside old code.
#
# This migration:
# - Adds runner-named columns on the providers and provider_states tables
#   alongside the old provider-named columns (NOT the tables themselves —
#   rename_table is deferred to phase 2)
# - Adds new runner-named columns on agent_runs, chat_sessions,
#   user_settings, and tenant_settings alongside the old provider-named
#   columns (add + backfill + keep old pattern)
# - Old columns are removed in phase 2 after this deploy lands.
#
# The Runner model uses self.table_name = "providers" until phase 2
# renames the table. Similarly RunnerState uses "provider_states".
#
# Phase 1 keeps the old provider-named indexes in place for legacy code and
# adds runner-named indexes for the new columns. The check constraints are
# renamed because their expressions do not reference provider_key.
class RenameProvidersToRunners < ActiveRecord::Migration[8.1]
  def up
    up_providers_columns
    up_provider_states_columns
    up_agent_runs_columns
    up_chat_sessions_columns
    up_user_settings_columns
    up_tenant_settings_columns
  end

  def down
    down_tenant_settings_columns
    down_user_settings_columns
    down_chat_sessions_columns
    down_agent_runs_columns
    down_provider_states_columns
    down_providers_columns
  end

  private

  # ── providers columns (table stays as "providers") ──────────────────

  def up_providers_columns
    rename_constraint(:providers,
      "providers_api_key_requires_key", "runners_api_key_requires_key")
    rename_constraint(:providers,
      "providers_subscription_invariants", "runners_subscription_invariants")
    rename_constraint(:providers,
      "providers_weight_positive", "runners_weight_positive")
    add_column :providers, :runner_key, :string, limit: 50

    backfill "UPDATE providers SET runner_key = provider_key"

    safety_assured { change_column_null :providers, :runner_key, false }
    safety_assured { change_column_null :providers, :provider_key, true }
    add_runner_unique_indexes
  end

  def down_providers_columns
    remove_runner_unique_indexes
    backfill "UPDATE providers SET provider_key = runner_key WHERE provider_key IS NULL"
    safety_assured { change_column_null :providers, :provider_key, false }
    safety_assured { remove_column :providers, :runner_key }

    rename_constraint(:providers,
      "runners_weight_positive", "providers_weight_positive")
    rename_constraint(:providers,
      "runners_subscription_invariants", "providers_subscription_invariants")
    rename_constraint(:providers,
      "runners_api_key_requires_key", "providers_api_key_requires_key")
  end

  # ── provider_states columns (table stays as "provider_states") ──────

  def up_provider_states_columns
    add_column :provider_states, :runner_name, :string, limit: 50

    backfill "UPDATE provider_states SET runner_name = provider_name"

    safety_assured { change_column_null :provider_states, :runner_name, false }
    safety_assured { change_column_null :provider_states, :provider_name, true }
    safety_assured do
      add_index :provider_states, [ :user_id, :runner_name ],
        unique: true, name: "index_provider_states_on_user_id_and_runner_name"
    end
  end

  def down_provider_states_columns
    safety_assured { remove_index :provider_states, name: "index_provider_states_on_user_id_and_runner_name" }
    backfill "UPDATE provider_states SET provider_name = runner_name WHERE provider_name IS NULL"
    safety_assured { change_column_null :provider_states, :provider_name, false }
    safety_assured { remove_column :provider_states, :runner_name }
  end

  # ── agent_runs columns ───────────────────────────────────────────────

  def up_agent_runs_columns
    add_column :agent_runs, :runner_id, :bigint
    add_column :agent_runs, :runner_switches, :integer, default: 0
    add_column :agent_runs, :runners_attempted, :jsonb, default: []
    add_column :agent_runs, :final_runner, :string, limit: 50

    backfill <<~SQL
      UPDATE agent_runs
      SET runner_id = provider_id,
          runner_switches = provider_switches,
          runners_attempted = providers_attempted,
          final_runner = final_provider
    SQL

    safety_assured { change_column_null :agent_runs, :runner_switches, false }
    safety_assured { change_column_null :agent_runs, :runners_attempted, false }
    safety_assured { add_index :agent_runs, :runner_id, name: "index_agent_runs_on_runner_id" }
    safety_assured do
      add_foreign_key :agent_runs, :providers,
        column: :runner_id, on_delete: :nullify,
        name: "fk_agent_runs_runner_id"
    end
  end

  def down_agent_runs_columns
    safety_assured { remove_foreign_key :agent_runs, name: "fk_agent_runs_runner_id" }
    change_column_null :agent_runs, :runners_attempted, true
    change_column_null :agent_runs, :runner_switches, true
    safety_assured { remove_column :agent_runs, :final_runner }
    safety_assured { remove_column :agent_runs, :runners_attempted }
    safety_assured { remove_column :agent_runs, :runner_switches }
    safety_assured { remove_column :agent_runs, :runner_id }
  end

  # ── chat_sessions columns ────────────────────────────────────────────

  def up_chat_sessions_columns
    add_column :chat_sessions, :runner_id, :bigint

    backfill "UPDATE chat_sessions SET runner_id = provider_id"

    safety_assured { add_index :chat_sessions, :runner_id, name: "index_chat_sessions_on_runner_id" }
    safety_assured do
      add_foreign_key :chat_sessions, :providers,
        column: :runner_id,
        name: "fk_chat_sessions_runner_id"
    end
  end

  def down_chat_sessions_columns
    safety_assured { remove_foreign_key :chat_sessions, name: "fk_chat_sessions_runner_id" }
    safety_assured { remove_column :chat_sessions, :runner_id }
  end

  # ── user_settings columns ────────────────────────────────────────────

  def up_user_settings_columns
    add_column :user_settings, :default_agent_runner, :string, default: "claude"
    add_column :user_settings, :default_agent_runners_by_goal, :jsonb, default: {}
    add_column :user_settings, :fallback_runners, :jsonb, default: []
    add_column :user_settings, :runner_selection_mode, :string, limit: 20, default: "single"
    add_column :user_settings, :runner_round_robin_state, :jsonb, default: {}
    add_column :user_settings, :kb_chat_runner, :string, default: "claude"
    add_column :user_settings, :kb_chat_fallback_runners, :jsonb, default: []
    add_column :user_settings, :kb_embedding_runner, :string, default: "openai"
    add_column :user_settings, :kb_embedding_fallback_runners, :jsonb, default: []

    backfill <<~SQL
      UPDATE user_settings
      SET default_agent_runner = default_agent_provider,
          default_agent_runners_by_goal = default_agent_providers_by_goal,
          fallback_runners = fallback_providers,
          runner_selection_mode = provider_selection_mode,
          runner_round_robin_state = provider_round_robin_state,
          kb_chat_runner = kb_chat_provider,
          kb_chat_fallback_runners = kb_chat_fallback_providers,
          kb_embedding_runner = kb_embedding_provider,
          kb_embedding_fallback_runners = kb_embedding_fallback_providers
    SQL

    safety_assured { change_column_null :user_settings, :default_agent_runner, false }
    safety_assured { change_column_null :user_settings, :default_agent_runners_by_goal, false }
    safety_assured { change_column_null :user_settings, :fallback_runners, false }
    safety_assured { change_column_null :user_settings, :runner_selection_mode, false }
    safety_assured { change_column_null :user_settings, :runner_round_robin_state, false }
    safety_assured { change_column_null :user_settings, :kb_chat_runner, false }
    safety_assured { change_column_null :user_settings, :kb_chat_fallback_runners, false }
    safety_assured { change_column_null :user_settings, :kb_embedding_runner, false }
    safety_assured { change_column_null :user_settings, :kb_embedding_fallback_runners, false }

    safety_assured do
      add_check_constraint :user_settings,
        "runner_selection_mode::text = ANY (ARRAY['single'::character varying::text, 'round_robin'::character varying::text, 'random'::character varying::text])",
        name: "chk_runner_selection_mode"
    end
  end

  def down_user_settings_columns
    remove_check_constraint :user_settings, name: "chk_runner_selection_mode"

    change_column_null :user_settings, :kb_embedding_runner, true
    change_column_null :user_settings, :kb_embedding_fallback_runners, true
    change_column_null :user_settings, :kb_chat_runner, true
    change_column_null :user_settings, :kb_chat_fallback_runners, true
    change_column_null :user_settings, :runner_round_robin_state, true
    change_column_null :user_settings, :runner_selection_mode, true
    change_column_null :user_settings, :fallback_runners, true
    change_column_null :user_settings, :default_agent_runners_by_goal, true
    change_column_null :user_settings, :default_agent_runner, true

    safety_assured { remove_column :user_settings, :kb_embedding_fallback_runners }
    safety_assured { remove_column :user_settings, :kb_embedding_runner }
    safety_assured { remove_column :user_settings, :kb_chat_fallback_runners }
    safety_assured { remove_column :user_settings, :kb_chat_runner }
    safety_assured { remove_column :user_settings, :runner_round_robin_state }
    safety_assured { remove_column :user_settings, :runner_selection_mode }
    safety_assured { remove_column :user_settings, :fallback_runners }
    safety_assured { remove_column :user_settings, :default_agent_runners_by_goal }
    safety_assured { remove_column :user_settings, :default_agent_runner }
  end

  # ── tenant_settings columns ──────────────────────────────────────────

  def up_tenant_settings_columns
    add_column :tenant_settings, :runner_preferences, :jsonb, default: {}
    add_column :tenant_settings, :allowed_runner_keys, :text, array: true, default: []

    backfill <<~SQL
      UPDATE tenant_settings
      SET runner_preferences = provider_preferences,
          allowed_runner_keys = allowed_provider_keys
    SQL

    safety_assured { change_column_null :tenant_settings, :runner_preferences, false }
  end

  def down_tenant_settings_columns
    change_column_null :tenant_settings, :runner_preferences, true
    safety_assured { remove_column :tenant_settings, :allowed_runner_keys }
    safety_assured { remove_column :tenant_settings, :runner_preferences }
  end

  # ── helpers ───────────────────────────────────────────────────────────

  def rename_constraint(table, old_name, new_name)
    safety_assured do
      execute "ALTER TABLE #{table} RENAME CONSTRAINT #{old_name} TO #{new_name}"
    end
  end

  def add_runner_unique_indexes
    safety_assured do
      add_index :providers, [ :user_id, :runner_key, :provider_api_key_id, :name ],
        unique: true,
        where: "auth_type = 'api_key' AND discarded_at IS NULL",
        name: "idx_runners_unique_api_key"
      add_index :providers, [ :user_id, :runner_key ],
        unique: true,
        where: "auth_type = 'subscription' AND discarded_at IS NULL",
        name: "idx_runners_unique_subscription"
    end
  end

  def remove_runner_unique_indexes
    safety_assured { remove_index :providers, name: "idx_runners_unique_subscription" }
    safety_assured { remove_index :providers, name: "idx_runners_unique_api_key" }
  end

  def backfill(sql)
    safety_assured { execute sql }
  end
end
