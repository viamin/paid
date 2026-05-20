# frozen_string_literal: true

module ProjectConventions
  class SyncRecommendations
    RECOMMENDATION_TYPE = "project_convention"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, detections:)
      @project = project
      @detections = detections.index_by { |detection| detection.fetch(:key) }
    end

    def call
      sync_hook_manager_recommendation
    end

    private

    attr_reader :project, :detections

    def sync_hook_manager_recommendation
      detection = detections["hook_manager"]
      existing = project.knowledge_recommendations.find_by(
        recommendation_type: RECOMMENDATION_TYPE,
        collector_type: "project_conventions"
      )

      unless detection
        existing&.dismiss!(reason: "Hook manager convention no longer detected")
        return
      end

      value = detection.fetch(:value)
      description = "Repository manages hooks with #{value.fetch("type")} (#{value.fetch("path")}). Prefer repo-managed guardrails over ad hoc local git hook setup."
      attributes = {
        priority: "medium",
        status: "pending",
        description: description,
        evidence: {
          "convention_key" => "hook_manager",
          "hook_manager" => value.fetch("type"),
          "detection" => detection.slice(:confidence, :evidence, :value)
        }
      }

      if existing
        existing.update!(attributes.except(:status))
      else
        project.knowledge_recommendations.create!(
          recommendation_type: RECOMMENDATION_TYPE,
          collector_type: "project_conventions",
          **attributes
        )
      end
    end
  end
end
