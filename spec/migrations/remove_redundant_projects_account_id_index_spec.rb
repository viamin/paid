# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128094514_remove_redundant_projects_account_id_index")

# PgHero flagged index_projects_on_account_id as a duplicate of
# index_projects_on_account_id_and_active (#5850): a btree index on
# (account_id, active) serves every account_id-only access path the legacy
# single-column index provides.
# @spec POSTGRESQL-PERSISTENCE-014
RSpec.describe RemoveRedundantProjectsAccountIdIndex do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    legacy_existed = index_present?(described_class::UNNEEDED_INDEX_NAME)
    ensure_index!([ :account_id ], described_class::UNNEEDED_INDEX_NAME) unless legacy_existed

    example.run
  ensure
    restore_original_indexes!(legacy_existed)
  end

  it "removes the redundant index and keeps the covering composite usable" do
    migration.up

    expect(index_present?(described_class::UNNEEDED_INDEX_NAME)).to be(false)
    expect(index_present?(described_class::COVERING_INDEX_NAME)).to be(true)
    expect(index_usable?(described_class::COVERING_INDEX_NAME)).to be(true)
    expect(leading_column(described_class::COVERING_INDEX_NAME)).to eq("account_id")
  end

  it "rolls back to the legacy single-column index" do
    migration.up

    expect { migration.down }.not_to raise_error

    expect(index_present?(described_class::UNNEEDED_INDEX_NAME)).to be(true)
    expect(index_unique?(described_class::UNNEEDED_INDEX_NAME)).to be(false)
    expect(index_usable?(described_class::UNNEEDED_INDEX_NAME)).to be(true)
    expect(index_present?(described_class::COVERING_INDEX_NAME)).to be(true)
  end

  it "reapplies the removal after a rollback" do
    migration.up
    migration.down

    expect { migration.up }.not_to raise_error

    expect(index_present?(described_class::UNNEEDED_INDEX_NAME)).to be(false)
    expect(index_usable?(described_class::COVERING_INDEX_NAME)).to be(true)
  end

  it "is a no-op when the redundant index is already absent" do
    connection.remove_index :projects, name: described_class::UNNEEDED_INDEX_NAME

    expect { migration.up }.not_to raise_error

    expect(index_present?(described_class::UNNEEDED_INDEX_NAME)).to be(false)
    expect(index_usable?(described_class::COVERING_INDEX_NAME)).to be(true)
  end

  it "refuses to remove the redundant index when the covering composite is missing" do
    connection.remove_index :projects, name: described_class::COVERING_INDEX_NAME

    begin
      expect { migration.up }.to raise_error(RuntimeError, /#{described_class::COVERING_INDEX_NAME}/)
    ensure
      ensure_index!([ :account_id, :active ], described_class::COVERING_INDEX_NAME)
    end

    expect(index_present?(described_class::UNNEEDED_INDEX_NAME)).to be(true)
    expect(index_usable?(described_class::COVERING_INDEX_NAME)).to be(true)
  end

  private

  def restore_original_indexes!(legacy_existed)
    if legacy_existed
      ensure_index!([ :account_id ], described_class::UNNEEDED_INDEX_NAME)
    else
      connection.remove_index :projects, name: described_class::UNNEEDED_INDEX_NAME, if_exists: true
    end
    ensure_index!([ :account_id, :active ], described_class::COVERING_INDEX_NAME)
  end

  def ensure_index!(columns, name)
    return if index_present?(name)

    connection.add_index :projects, columns, name: name
  end

  def index_present?(name)
    connection.select_value("SELECT to_regclass(#{connection.quote(name)}) IS NOT NULL")
  end

  def index_usable?(name)
    connection.select_value(<<~SQL.squish)
      SELECT indisvalid AND indisready
      FROM pg_index
      WHERE indexrelid = to_regclass(#{connection.quote(name)})
    SQL
  end

  def index_unique?(name)
    connection.select_value(<<~SQL.squish)
      SELECT indisunique
      FROM pg_index
      WHERE indexrelid = to_regclass(#{connection.quote(name)})
    SQL
  end

  def leading_column(name)
    connection.select_value(<<~SQL.squish)
      SELECT a.attname
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
      WHERE i.indexrelid = to_regclass(#{connection.quote(name)})
    SQL
  end
end
