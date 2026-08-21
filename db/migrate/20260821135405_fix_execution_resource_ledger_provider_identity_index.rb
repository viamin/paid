# frozen_string_literal: true

# @spec RESOURCE-LEDGER-001
class FixExecutionResourceLedgerProviderIdentityIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_execution_resource_ledger_provider_identity"
  INDEX_COLUMNS = [ :runner_type, :backend, :provider_resource_id ].freeze
  INDEX_WHERE = "provider_resource_id IS NOT NULL"

  disable_ddl_transaction!

  def up
    recreate_provider_identity_index(nulls_not_distinct: true)
  end

  def down
    recreate_provider_identity_index(nulls_not_distinct: false)
  end

  private

  def recreate_provider_identity_index(nulls_not_distinct:)
    current_index = provider_identity_index
    return if current_index&.nulls_not_distinct == nulls_not_distinct

    remove_index :execution_resource_ledger_entries, name: INDEX_NAME, algorithm: :concurrently if current_index

    options = {
      unique: true,
      where: INDEX_WHERE,
      name: INDEX_NAME,
      algorithm: :concurrently
    }
    options[:nulls_not_distinct] = true if nulls_not_distinct

    add_index :execution_resource_ledger_entries, INDEX_COLUMNS, **options
  end

  def provider_identity_index
    connection.indexes(:execution_resource_ledger_entries).find { |index| index.name == INDEX_NAME }
  end
end
