# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128080515_remove_duplicate_intent_checkpoint_settlement_index")

RSpec.describe RemoveDuplicateIntentCheckpointSettlementIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:duplicate_index) { described_class::DUPLICATE_INDEX }
  let(:covering_index) { described_class::COVERING_INDEX }

  around do |example|
    ensure_duplicate_index
    example.run
  ensure
    remove_duplicate_index
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the catalog-confirmed redundant index and restores it on rollback" do
    expect(index_columns(duplicate_index)).to eq([ "intent_checkpoint_id" ])
    expect(index_columns(covering_index)).to eq([ "intent_checkpoint_id", "created_at" ])
    expect(index_metadata(duplicate_index)).to eq("indisvalid" => true, "is_partial" => false)
    expect(index_metadata(covering_index)).to eq("indisvalid" => true, "is_partial" => false)

    described_class.new.up

    expect(index_exists?(duplicate_index)).to be(false)
    expect(index_columns(covering_index)).to eq([ "intent_checkpoint_id", "created_at" ])

    described_class.new.down

    expect(index_columns(duplicate_index)).to eq([ "intent_checkpoint_id" ])
  end

  private

  def ensure_duplicate_index
    return if index_exists?(duplicate_index)

    connection.add_index :project_delegation_intent_settlements, :intent_checkpoint_id,
      name: duplicate_index, algorithm: :concurrently
  end

  def index_exists?(index_name)
    connection.index_exists?(:project_delegation_intent_settlements, name: index_name)
  end

  def remove_duplicate_index
    connection.remove_index :project_delegation_intent_settlements,
      name: duplicate_index, algorithm: :concurrently, if_exists: true
  end

  def index_columns(index_name)
    connection.select_values(<<~SQL.squish)
      SELECT attribute.attname
      FROM pg_index AS index
      JOIN unnest(index.indkey) WITH ORDINALITY AS key(attnum, position) ON key.attnum > 0
      JOIN pg_attribute AS attribute ON attribute.attrelid = index.indrelid AND attribute.attnum = key.attnum
      WHERE index.indexrelid = to_regclass(#{connection.quote(index_name)})
      ORDER BY key.position
    SQL
  end

  def index_metadata(index_name)
    connection.select_one(<<~SQL.squish)
      SELECT index.indisvalid, index.indpred IS NOT NULL AS is_partial
      FROM pg_index AS index
      WHERE index.indexrelid = to_regclass(#{connection.quote(index_name)})
    SQL
  end
end
