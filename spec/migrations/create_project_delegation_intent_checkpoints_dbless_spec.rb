# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117100000_create_project_delegation_intent_checkpoints")

RSpec.describe CreateProjectDelegationIntentCheckpoints, :no_db do
  # @spec PROJECT-DELEGATION-002
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive(:create_table)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:add_reference)
    allow(migration).to receive(:create_function)
    allow(migration).to receive(:create_trigger)
    allow(migration).to receive(:safety_assured).and_yield
  end

  it "builds the settlement policy binding the human settler to the current account" do
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    sql = recorded_sql.join("\n")
    expect(sql).to include("CREATE POLICY tenant_isolation ON project_delegation_intent_settlements")
    # Both the read (USING) and write (WITH CHECK) clauses must prove the
    # settler belongs to the current account, not merely exist.
    expect(sql.scan("users.id = project_delegation_intent_settlements.settled_by_id").length).to be >= 2
    expect(sql.scan("users.account_id = paid_current_account_id()").length).to be >= 2
  end
end
