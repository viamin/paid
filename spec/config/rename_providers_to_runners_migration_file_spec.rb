# frozen_string_literal: true

require "rails_helper"

class RenameProvidersToRunnersMigrationFile < Pathname
end

RSpec.describe RenameProvidersToRunnersMigrationFile, :no_db do
  subject(:migration_source) do
    Rails.root.join("db/migrate/20260511171813_rename_providers_to_runners.rb").read
  end

  it "backfills legacy provider columns from runner columns before phase-1 rollback drops the bridge columns",
    :aggregate_failures do
    expect(migration_source).to include('UPDATE providers SET provider_key = runner_key')
    expect(migration_source).to include('UPDATE provider_states SET provider_name = runner_name')
    expect(migration_source).to include("SET provider_id = runner_id,")
    expect(migration_source).to include("provider_switches = runner_switches,")
    expect(migration_source).to include("providers_attempted = runners_attempted,")
    expect(migration_source).to include("final_provider = final_runner")
    expect(migration_source).to include('UPDATE chat_sessions SET provider_id = runner_id')
    expect(migration_source).to include("SET default_agent_provider = default_agent_runner,")
    expect(migration_source).to include("provider_selection_mode = runner_selection_mode,")
    expect(migration_source).to include("kb_embedding_fallback_providers = kb_embedding_fallback_runners")
    expect(migration_source).to include("SET provider_preferences = runner_preferences,")
    expect(migration_source).to include("allowed_provider_keys = allowed_runner_keys")
  end
end
