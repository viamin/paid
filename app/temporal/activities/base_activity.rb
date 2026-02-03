# frozen_string_literal: true

require "temporalio/activity"

module Activities
  class BaseActivity
    extend Temporalio::Activity::Definition

    protected

    def logger
      Rails.logger
    end

    def update_workflow_state(workflow_id, attributes)
      WorkflowState.find_or_create_by(temporal_workflow_id: workflow_id)
                   .update!(attributes)
    end
  end
end
