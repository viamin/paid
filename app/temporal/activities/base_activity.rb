# frozen_string_literal: true

require "temporalio/activity"

module Activities
  # Base class for all Temporal activities in this application.
  #
  # Inherits from Temporalio::Activity::Definition as per the temporalio gem v1.2.0 API.
  # Activities must implement an `execute` method which will be called by the Temporal worker.
  class BaseActivity < Temporalio::Activity::Definition
    protected

    def logger
      Rails.logger
    end

    def update_workflow_state(workflow_id, attributes)
      WorkflowState.upsert(
        attributes.merge(temporal_workflow_id: workflow_id),
        unique_by: :temporal_workflow_id
      )
    end
  end
end
