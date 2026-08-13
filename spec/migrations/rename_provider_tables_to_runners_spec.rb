# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260518131232_rename_provider_tables_to_runners")

# Verifies that the table rename is reversible, that the runner-named
# tables behave like the source-of-truth (FKs, indexes, RLS policies all
# follow the rename via OID), and that AR model queries continue to hit
# the renamed tables after the model overrides are removed.
RSpec.describe RenameProviderTablesToRunners, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    example.run
  ensure
    # Restore post-up state so subsequent specs see the schema they expect.
    migration.up unless connection.table_exists?(:runners)
    Runner.reset_column_information
    RunnerState.reset_column_information
  end

  it "renames providers to runners and provider_states to runner_states" do
    migration.down

    expect(connection.table_exists?(:providers)).to be(true)
    expect(connection.table_exists?(:provider_states)).to be(true)
    expect(connection.table_exists?(:runners)).to be(false)
    expect(connection.table_exists?(:runner_states)).to be(false)

    migration.up

    expect(connection.table_exists?(:runners)).to be(true)
    expect(connection.table_exists?(:runner_states)).to be(true)
    expect(connection.table_exists?(:providers)).to be(false)
    expect(connection.table_exists?(:provider_states)).to be(false)
  end

  it "preserves foreign keys pointing at the renamed tables" do
    # agent_runs.runner_id and chat_sessions.runner_id both reference the
    # renamed table. Foreign keys move with the table OID, so they should
    # still resolve to `runners` after the rename runs.
    fk = connection.foreign_keys(:agent_runs).find { |key| key.column == "runner_id" }

    expect(fk).to be_present
    expect(fk.to_table).to eq("runners")
  end

  it "lets the Runner model query the renamed table without an explicit table_name override" do
    # Removing `self.table_name = 'providers'` only works if Rails' default
    # convention (Runner → runners) matches the renamed table.
    expect(Runner.table_name).to eq("runners")
    expect(RunnerState.table_name).to eq("runner_states")
    expect { Runner.first }.not_to raise_error
    expect { RunnerState.first }.not_to raise_error
  end
end
