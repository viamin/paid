# frozen_string_literal: true

# idx_context_intake_responses_session_question covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5501 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :context_intake_responses, name: "index_context_intake_responses_on_context_intake_session_id", algorithm: :concurrently
  end

  def down
    add_index :context_intake_responses, [ :context_intake_session_id ],
      name: "index_context_intake_responses_on_context_intake_session_id", algorithm: :concurrently
  end
end
