# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260513120000_add_focus_to_agent_runs")

RSpec.describe AddFocusToAgentRuns, :no_db do
  let(:migration) { described_class.new }

  it "disables the DDL transaction so the index can build concurrently" do
    expect(described_class.disable_ddl_transaction).to be true
  end

  it "adds the column and builds the index concurrently on a fresh database" do
    allow(migration).to receive_messages(column_exists?: false, index_exists?: false, add_column: nil, add_index: nil)

    migration.up

    expect(migration).to have_received(:add_column).with(
      :agent_runs,
      :focus,
      :string,
      limit: 50,
      default: "general",
      null: false,
      comment: "Focused run intent derived from the highest-priority PR trigger or assigned workflow context."
    )
    expect(migration).to have_received(:add_index).with(:agent_runs, :focus, algorithm: :concurrently)
  end

  it "re-runs safely when the column and index already exist" do
    allow(migration).to receive_messages(column_exists?: true, index_exists?: true, add_column: nil, add_index: nil)

    migration.up

    expect(migration).not_to have_received(:add_column)
    expect(migration).not_to have_received(:add_index)
  end
end
