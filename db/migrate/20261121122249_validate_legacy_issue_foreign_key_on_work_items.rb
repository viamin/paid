class ValidateLegacyIssueForeignKeyOnWorkItems < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    validate_foreign_key :work_items, :issues, column: :legacy_issue_id
  end

  def down
  end
end
