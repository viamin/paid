# frozen_string_literal: true

require "rails_helper"

class RunnerSchemaBridgeFile < Pathname
end

RSpec.describe RunnerSchemaBridgeFile, :no_db do
  subject(:schema) { Rails.root.join("db/schema.rb").read }

  it "keeps both provider and runner columns on the bridge tables used by fresh schema loads" do
    expect(schema).to include('t.string "provider_name", limit: 50')
    expect(schema).to include('t.string "runner_name", limit: 50, null: false')
    expect(schema).to include('t.string "provider_key", limit: 50')
    expect(schema).to include('t.string "runner_key", limit: 50, null: false')
  end

  it "keeps both provider and runner lookup indexes that bridge the rename" do
    # Phase 2 (#2115) renamed the `providers`/`provider_states` tables.
    # Rails' rename_table auto-renames indexes whose names embed the
    # table name (the `index_<table>_on_*` Rails convention), so the
    # paired runner_states lookup indexes are now both named with the
    # renamed table. Custom-named indexes (`idx_*`) stay put, so both
    # `idx_providers_unique_*` and `idx_runners_unique_*` survive on
    # the renamed `runners` table.
    expect(schema).to include('name: "index_runner_states_on_user_id_and_provider_name", unique: true')
    expect(schema).to include('name: "index_runner_states_on_user_id_and_runner_name", unique: true')
    expect(schema).to include('name: "idx_providers_unique_api_key", unique: true')
    expect(schema).to include('name: "idx_providers_unique_subscription", unique: true')
    expect(schema).to include('name: "idx_runners_unique_api_key", unique: true')
    expect(schema).to include('name: "idx_runners_unique_subscription", unique: true')
  end
end
