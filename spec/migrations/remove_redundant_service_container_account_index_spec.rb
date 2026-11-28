# frozen_string_literal: true

require "rails_helper"
require Rails.root.glob("db/migrate/*_remove_redundant_service_container_account_index.rb").sole

RSpec.describe RemoveRedundantServiceContainerAccountIndex do # @spec POSTGRESQL-PERSISTENCE-043
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:legacy) { "index_service_containers_on_account_id" }
  let(:coverer) { "index_service_containers_on_account_id_and_name" }

  around do |example|
    schema = "pghero_service_containers_#{SecureRandom.hex(6)}"
    previous_path = connection.schema_search_path
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.schema_search_path = schema
      connection.create_table(:service_containers) do |t|
        t.bigint :account_id
        t.string :name
        t.string :status
      end
      connection.add_index :service_containers, :account_id, name: legacy
      connection.add_index :service_containers, %i[account_id name], name: coverer, unique: true
      connection.add_index :service_containers, %i[account_id status], name: "retained_status_lookup"
      connection.execute("INSERT INTO service_containers (account_id, name, status) VALUES (1, 'primary', 'pending')")
      example.run
    ensure
      connection.schema_search_path = previous_path
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  it "removes only the redundant prefix and preserves all records" do
    original = indexes
    rows = connection.select_all("SELECT * FROM service_containers").to_a
    migration.migrate(:up)

    expect(indexes).to eq(original.except(legacy))
    expect(connection.select_all("SELECT * FROM service_containers").to_a).to eq(rows)
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
    connection.remove_index :service_containers, name: coverer, unique: true
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects a partial coverer without removing the original index" do
    connection.remove_index :service_containers, name: coverer, unique: true
    connection.add_index :service_containers, %i[account_id name], name: coverer, unique: true,
      where: "name IS NOT NULL"
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "preserves a changed account uniqueness contract" do
    connection.remove_index :service_containers, name: legacy
    connection.add_index :service_containers, :account_id, name: legacy, unique: true
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects an invalid coverer left by a failed concurrent build" do
    connection.remove_index :service_containers, name: coverer, unique: true
    connection.execute("INSERT INTO service_containers (account_id, name) VALUES (1, '2026-11-28'), (1, '2026-11-28')")
    expect do
      connection.add_index :service_containers, %i[account_id name],
        name: coverer, unique: true, algorithm: :concurrently
    end.to raise_error(ActiveRecord::RecordNotUnique)
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "rejects different coverer keys without removing the original index" do
    connection.remove_index :service_containers, name: coverer, unique: true
    connection.add_index :service_containers, %i[status account_id], name: coverer, unique: true
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "requires the retained account/name uniqueness contract" do
    connection.remove_index :service_containers, name: coverer
    connection.add_index :service_containers, %i[account_id name], name: coverer
    original = indexes

    expect { migration.migrate(:up) }.to raise_error(ActiveRecord::MigrationError)
    expect(indexes).to eq(original)
  end

  it "retains unique names per account without excluding other accounts" do
    migration.migrate(:up)
    statement = "INSERT INTO service_containers (account_id, name) VALUES (1, 'primary')"

    expect { connection.execute(statement) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { connection.execute(statement.sub("VALUES (1,", "VALUES (2,")) }.not_to raise_error
  end

  def indexes
    connection.indexes(:service_containers).to_h do |index|
      [ index.name, [ index.columns, index.unique, index.where, index.valid? ] ]
    end
  end
end
