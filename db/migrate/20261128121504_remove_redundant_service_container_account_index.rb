# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-043
class RemoveRedundantServiceContainerAccountIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_service_containers_on_account_id"
  COVERING_INDEX_NAME = "index_service_containers_on_account_id_and_name"

  def up
    indexes = connection.indexes(:service_containers)
    original = indexes.find { |index| index.name == INDEX_NAME }
    return unless original

    unless original.columns == [ "account_id" ] && !original.unique && original.where.nil?
      raise ActiveRecord::MigrationError, "Service container account index no longer matches the nonunique prefix"
    end

    coverer = indexes.find { |index| index.name == COVERING_INDEX_NAME }
    unless coverer && coverer.unique && coverer.valid? && coverer.where.nil? && coverer.using == :btree &&
        coverer.columns == %w[account_id name]
      raise ActiveRecord::MigrationError, "Service container name coverer must be a valid full unique btree index"
    end

    remove_index :service_containers, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    add_index :service_containers, :account_id, name: INDEX_NAME,
      algorithm: :concurrently, if_not_exists: true
  end
end
