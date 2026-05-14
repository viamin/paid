# frozen_string_literal: true

require "rails_helper"

class RunnerSchemaBridgeFile < Pathname
end

RSpec.describe RunnerSchemaBridgeFile, :no_db do
  subject(:schema) { Rails.root.join("db/schema.rb").read }

  it "keeps both provider and runner columns on the bridge tables used by fresh schema loads" do
    expect(schema).to include('t.string "provider_name", limit: 50, null: false')
    expect(schema).to include('t.string "runner_name", limit: 50, null: false')
    expect(schema).to include('t.string "provider_key", limit: 50, null: false')
    expect(schema).to include('t.string "runner_key", limit: 50, null: false')
  end

  it "keeps both provider and runner lookup indexes required during phase 1" do
    expect(schema).to include('name: "index_provider_states_on_user_id_and_provider_name", unique: true')
    expect(schema).to include('name: "index_provider_states_on_user_id_and_runner_name", unique: true')
  end
end
