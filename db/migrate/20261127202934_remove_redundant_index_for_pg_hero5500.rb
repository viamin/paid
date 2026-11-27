# frozen_string_literal: true

# idx_context_intake_questions_round_order covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5500 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :context_intake_questions, name: "index_context_intake_questions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :context_intake_questions, [ :project_id ],
      name: "index_context_intake_questions_on_project_id", algorithm: :concurrently
  end
end
