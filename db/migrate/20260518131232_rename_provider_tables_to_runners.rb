# frozen_string_literal: true

# Phase 2 of the providers-to-runners rename. Requires phase 1 (#1950)
# deployed first.
#
# Renames the underlying `providers` and `provider_states` tables to
# `runners` and `runner_states` to match the application-level rename
# already in place. The legacy provider-named columns in agent_runs,
# chat_sessions, user_settings, and tenant_settings are intentionally
# left in place — those are managed by the LegacyAttributeBridge in
# their respective models during the migration window, and will be
# dropped in a separate follow-up once dependent specs/code are audited.
class RenameProviderTablesToRunners < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      rename_table :providers, :runners
      rename_table :provider_states, :runner_states
    end
  end

  def down
    safety_assured do
      rename_table :runner_states, :provider_states
      rename_table :runners, :providers
    end
  end
end
