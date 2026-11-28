# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-014
class RemoveRedundantProjectsAccountIdIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  UNNEEDED_INDEX_NAME = "index_projects_on_account_id"
  COVERING_INDEX_NAME = "index_projects_on_account_id_and_active"
  COVERING_LEADING_COLUMN = "account_id"

  def up
    return unless index_present?(UNNEEDED_INDEX_NAME)

    ensure_covering_index!
    remove_index :projects, name: UNNEEDED_INDEX_NAME, algorithm: :concurrently
  end

  def down
    return if index_present?(UNNEEDED_INDEX_NAME)

    add_index :projects, :account_id, name: UNNEEDED_INDEX_NAME, algorithm: :concurrently
  end

  private

  # Catalog reads stay accurate regardless of Rails schema-cache staleness from
  # index DDL earlier in the same process.
  def index_present?(name)
    connection.select_value("SELECT to_regclass(#{connection.quote(name)}) IS NOT NULL")
  end

  def ensure_covering_index!
    covering = connection.select_one(<<~SQL.squish)
      SELECT i.indisvalid AND i.indisready AS usable, a.attname AS leading_column
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
      WHERE i.indexrelid = to_regclass(#{connection.quote(COVERING_INDEX_NAME)})
    SQL
    return if covering && covering.fetch("usable") && covering.fetch("leading_column") == COVERING_LEADING_COLUMN

    raise "Refusing to remove #{UNNEEDED_INDEX_NAME}: covering index #{COVERING_INDEX_NAME} " \
      "is missing, invalid, or does not lead with #{COVERING_LEADING_COLUMN}"
  end
end
