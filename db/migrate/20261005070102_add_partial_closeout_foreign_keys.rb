# frozen_string_literal: true

class AddPartialCloseoutForeignKeys < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :agent_runs, :issue_continuation_requests, column: :continuation_request_id, on_delete: :nullify, validate: false unless foreign_key_exists?(:agent_runs, :issue_continuation_requests, column: :continuation_request_id)
    add_foreign_key :issues, :users, column: :closeout_resolved_by_id, validate: false unless foreign_key_exists?(:issues, :users, column: :closeout_resolved_by_id)
  end

  def down
    remove_foreign_key :issues, column: :closeout_resolved_by_id if foreign_key_exists?(:issues, column: :closeout_resolved_by_id)
    remove_foreign_key :agent_runs, column: :continuation_request_id if foreign_key_exists?(:agent_runs, column: :continuation_request_id)
  end
end
