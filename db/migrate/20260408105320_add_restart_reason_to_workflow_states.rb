# frozen_string_literal: true

class AddRestartReasonToWorkflowStates < ActiveRecord::Migration[8.1]
  def change
    add_column :workflow_states, :restart_reason, :text
  end
end
