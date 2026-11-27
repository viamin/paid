# frozen_string_literal: true

# idx_code_scanning_remediation_attempts_unique_pr covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5490 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :code_scanning_remediation_attempts, name: "index_code_scanning_remediation_attempts_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :code_scanning_remediation_attempts, [ :issue_id ],
      name: "index_code_scanning_remediation_attempts_on_issue_id", algorithm: :concurrently
  end
end
