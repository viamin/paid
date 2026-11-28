# frozen_string_literal: true

require "rails_helper"
require Rails.root.glob("db/migrate/*_remove_redundant_remediation_account_index.rb").sole

RSpec.describe RemoveRedundantRemediationAccountIndex do # @spec POSTGRESQL-PERSISTENCE-042
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:legacy) { "index_remediation_decisions_on_account_id" }
  let(:coverer) { "idx_remediation_decisions_budget_lookup" }

  around do |example|
    schema = "pghero_remediation_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      connection.create_table(:remediation_decisions) do |t|
        t.bigint :account_id
        t.date :diagnosis_attempted_on
        t.string :status
      end
      connection.add_index :remediation_decisions, :account_id, name: legacy
      connection.add_index :remediation_decisions, %i[account_id diagnosis_attempted_on], name: coverer
      connection.add_index :remediation_decisions, %i[account_id status], name: "retained_status_lookup"
      connection.execute("INSERT INTO remediation_decisions (account_id, status) VALUES (1, 'pending')")
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  it "removes only the redundant prefix and preserves all records" do
    original = indexes
    rows = connection.select_all("SELECT * FROM remediation_decisions").to_a
    migration.migrate(:up)

    expect(indexes).to eq(original.except(legacy))
    expect(connection.select_all("SELECT * FROM remediation_decisions").to_a).to eq(rows)
  end

  it "restores the exact original catalog and permits reapplication" do
    original = indexes
    migration.migrate(:up)
    migration.migrate(:down)
    expect(indexes).to eq(original)
    migration.migrate(:up)
    expect(indexes).not_to have_key(legacy)
  end

  it "rejects a missing coverer without removing the original index" do
    connection.remove_index :remediation_decisions, name: coverer
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects a partial coverer without removing the original index" do
    connection.remove_index :remediation_decisions, name: coverer
    connection.add_index :remediation_decisions, %i[account_id diagnosis_attempted_on], name: coverer,
      where: "diagnosis_attempted_on IS NOT NULL"
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "preserves a changed account uniqueness contract" do
    connection.remove_index :remediation_decisions, name: legacy
    connection.add_index :remediation_decisions, :account_id, name: legacy, unique: true
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects an invalid coverer left by a failed concurrent build" do
    connection.remove_index :remediation_decisions, name: coverer
    connection.execute("INSERT INTO remediation_decisions (account_id, diagnosis_attempted_on) VALUES (1, '2026-11-28'), (1, '2026-11-28')")
    expect do
      connection.add_index :remediation_decisions, %i[account_id diagnosis_attempted_on],
        name: coverer, unique: true, algorithm: :concurrently
    end.to raise_error(ActiveRecord::RecordNotUnique)
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects different coverer keys without removing the original index" do
    connection.remove_index :remediation_decisions, name: coverer
    connection.add_index :remediation_decisions, %i[status account_id], name: coverer
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  def indexes
    connection.indexes(:remediation_decisions).to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where, index.valid? ] ]
    end
  end
end
