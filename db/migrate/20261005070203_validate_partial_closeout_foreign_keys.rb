# frozen_string_literal: true

# Validates the partial-closeout foreign keys added (validate: false) by
# AddPartialCloseoutForeignKeys. The `issues` -> `users` table pair also
# carries a pre-existing `reopened_by_id` foreign key, so the column must be
# named explicitly — `validate_foreign_key :issues, :users` would otherwise
# resolve the first matching constraint (reopened_by_id) and leave the new
# referential-integrity safeguard permanently unenforced (#4130 review).
class ValidatePartialCloseoutForeignKeys < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :agent_runs, :issue_continuation_requests, column: :continuation_request_id if foreign_key_exists?(:agent_runs, :issue_continuation_requests, column: :continuation_request_id)

    validate_foreign_key :issues, :users, column: :closeout_resolved_by_id if foreign_key_exists?(:issues, :users, column: :closeout_resolved_by_id)
  end

  def down
  end
end
