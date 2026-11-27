# frozen_string_literal: true

# index_clarifying_question_progresses_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5489 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :clarifying_question_progresses, name: "index_clarifying_question_progresses_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :clarifying_question_progresses, [ :issue_id ],
      name: "index_clarifying_question_progresses_on_issue_id", algorithm: :concurrently
  end
end
