# frozen_string_literal: true

module QualityAlerts
  class CheckGateJob < ApplicationJob
    queue_as :metrics

    def perform(project_id:)
      project = Project.find(project_id)
      return unless project.quality_gates_enabled?

      CheckGate.call(project: project)
    end
  end
end
