# frozen_string_literal: true

class AddInboxFieldsToChangeIntents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:change_intents, :requested_changes_at)
      add_column :change_intents, :requested_changes_at, :datetime,
        comment: "When the latest operator review requested changes to this draft Change Intent Record."
    end
    unless column_exists?(:change_intents, :requested_changes_reason)
      add_column :change_intents, :requested_changes_reason, :text,
        comment: "Operator-visible reason captured when the latest review requested changes on this draft."
    end
    unless index_exists?(:change_intents, :requested_changes_at)
      add_index :change_intents, :requested_changes_at,
        where: "requested_changes_at IS NOT NULL",
        algorithm: :concurrently
    end
  end

  def down
    remove_index :change_intents, :requested_changes_at, algorithm: :concurrently, if_exists: true
    remove_column :change_intents, :requested_changes_reason if column_exists?(:change_intents, :requested_changes_reason)
    remove_column :change_intents, :requested_changes_at if column_exists?(:change_intents, :requested_changes_at)
  end
end
