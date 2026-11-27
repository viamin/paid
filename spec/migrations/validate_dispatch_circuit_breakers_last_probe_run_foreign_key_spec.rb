# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127192601_validate_dispatch_circuit_breakers_last_probe_run_foreign_key")

RSpec.describe ValidateDispatchCircuitBreakersLastProbeRunForeignKey do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    original = probe_foreign_key
    connection.remove_foreign_key :dispatch_circuit_breakers, column: :last_probe_run_id
    connection.add_foreign_key :dispatch_circuit_breakers, :agent_runs,
      column: :last_probe_run_id, on_delete: :nullify, validate: false
    connection.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    connection.validate_foreign_key :dispatch_circuit_breakers, :agent_runs,
      column: :last_probe_run_id if original&.validated?
  end

  def probe_foreign_key
    connection.foreign_keys(:dispatch_circuit_breakers).find { |key| key.column == "last_probe_run_id" }
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "validates existing references without modifying rows or delete behavior" do
    account = create(:account)
    run = create(:agent_run, project: create(:project, account: account))
    breaker = create(:dispatch_circuit_breaker, account: account, last_probe_run_id: run.id)
    before = breaker.attributes

    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }

    expect(probe_foreign_key).to be_validated
    expect(probe_foreign_key.on_delete).to eq(:nullify)
    expect(breaker.reload.attributes).to eq(before)
    connection.execute("DELETE FROM agent_runs WHERE id = #{run.id}")
    expect(breaker.reload.last_probe_run_id).to be_nil
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "preserves validation and the foreign key when rolled back" do
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:up)
      migration.migrate(:down)
    end

    expect(probe_foreign_key).to be_validated
    expect(probe_foreign_key.on_delete).to eq(:nullify)
  end
end
