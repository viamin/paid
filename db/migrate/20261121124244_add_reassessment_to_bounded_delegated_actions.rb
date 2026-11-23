class AddReassessmentToBoundedDelegatedActions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :bounded_delegated_actions, :reassessment_required_at, :datetime
    add_column :bounded_delegated_actions, :reassessment_reasons, :jsonb, default: [], null: false
    add_index :bounded_delegated_actions, :reassessment_required_at, algorithm: :concurrently
  end
end
