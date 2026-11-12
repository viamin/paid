# frozen_string_literal: true

# @spec BOUNDED-PHASE-AUTHORIZATION-004 @spec BOUNDED-PHASE-AUTHORIZATION-005
# @spec BOUNDED-PHASE-AUTHORIZATION-009 @spec PROJECT-DELEGATION-006
class AddLifecycleToBoundedDelegatedActions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :bounded_delegated_actions, :status_reason, :string
    add_column :bounded_delegated_actions, :lifecycle_evidence, :jsonb, null: false, default: {}
    add_column :bounded_delegated_actions, :lifecycle_changed_at, :datetime
    add_index :bounded_delegated_actions, [ :status, :lifecycle_changed_at ],
      name: "index_bounded_actions_on_status_and_lifecycle_change", algorithm: :concurrently
  end
end
