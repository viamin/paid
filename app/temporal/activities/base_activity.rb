# frozen_string_literal: true

require "temporalio/activity"

module Activities
  class BaseActivity < Temporalio::Activity::Definition

    protected

    def logger
      Rails.logger
    end

    def update_workflow_state(workflow_id, attributes)
      WorkflowState.find_or_initialize_by(temporal_workflow_id: workflow_id)
                   .update!(attributes)
    end
  end
end
