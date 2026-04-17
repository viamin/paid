# frozen_string_literal: true

class AddTenantLifecycleToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :status, :integer, null: false, default: 0
    add_column :accounts, :suspended_at, :datetime
    add_column :accounts, :deactivated_at, :datetime
    add_index :accounts, :status
  end
end
