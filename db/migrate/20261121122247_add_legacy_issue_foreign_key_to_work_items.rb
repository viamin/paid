class AddLegacyIssueForeignKeyToWorkItems < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_foreign_key :work_items, :issues, column: :legacy_issue_id, validate: false
  end

  def down
    remove_foreign_key :work_items, column: :legacy_issue_id
  end
end
