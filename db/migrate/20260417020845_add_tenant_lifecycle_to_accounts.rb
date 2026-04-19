# frozen_string_literal: true

class AddTenantLifecycleToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :status, :integer, null: false, default: 0 unless column_exists?(:accounts, :status)
    add_column :accounts, :suspended_at, :datetime unless column_exists?(:accounts, :suspended_at)
    add_column :accounts, :deactivated_at, :datetime unless column_exists?(:accounts, :deactivated_at)
    add_index :accounts, :status unless index_exists?(:accounts, :status)
  end
end
