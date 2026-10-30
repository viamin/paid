# frozen_string_literal: true

class AddRemoteIdentityToAgentPlanningHolds < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    change_column_null :agent_planning_holds, :issue_id, true
    add_column :agent_planning_holds, :remote_issue_number, :integer, null: false
    add_index :agent_planning_holds, [ :project_id, :remote_issue_number, :label ],
      unique: true, name: "index_agent_planning_holds_on_remote_issue_and_label", algorithm: :concurrently
  end
end
