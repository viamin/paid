# frozen_string_literal: true

class RemoveRedundantWorkItemIdentityIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-025
  def up
    remove_index :work_item_lifecycle_conflicts, name: "index_work_item_lifecycle_conflicts_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :work_item_lifecycle_mappings, name: "index_work_item_lifecycle_mappings_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :work_item_project_mappings, name: "index_work_item_project_mappings_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :work_items, name: "index_work_items_on_account_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :work_item_lifecycle_conflicts, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_item_lifecycle_mappings, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_item_project_mappings, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_items, :account_id, algorithm: :concurrently, if_not_exists: true
  end
end
