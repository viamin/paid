# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127210648_remove_redundant_index_for_pg_hero5571")

RSpec.describe RemoveRedundantIndexForPgHero5571 do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:removed_columns) do
    {
      "index_integration_credentials_on_account_id" => %w[account_id],
      "index_integration_credentials_on_account_id_and_service_key" => %w[account_id service_key]
    }
  end
  let(:covering_name) { "idx_on_account_id_service_key_name_e4c03e1ea7" }

  def indexes
    connection.indexes(:integration_credentials).to_h { |index| [ index.name, index ] }
  end

  def definition(index)
    [ index.columns, index.unique, index.using, index.where, index.orders, index.opclasses, index.comment ]
  end

  before do
    removed_columns.each do |name, columns|
      connection.add_index :integration_credentials, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-022
  it "resolves both covered-index findings and restores both definitions on rollback" do
    original = removed_columns.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }
    covering = definition(indexes.fetch(covering_name))
    count = connection.select_value("SELECT COUNT(*) FROM integration_credentials")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(indexes.keys & removed_columns.keys).to be_empty
    expect(definition(indexes.fetch(covering_name))).to eq(covering)
    expect(connection.select_value("SELECT COUNT(*) FROM integration_credentials")).to eq(count)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    expect(original.keys.to_h { |name| [ name, definition(indexes.fetch(name)) ] }).to eq(original)
  ensure
    removed_columns.each do |name, columns|
      connection.add_index :integration_credentials, columns, name: name, algorithm: :concurrently unless indexes.key?(name)
    end
  end
end
