# frozen_string_literal: true

module Tools
  # @spec AUTOMATION-PHASES-002 AUTOMATION-PHASES-008 AUTOMATION-PHASES-014
  class GetProjectAutomationPhases < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "get_project_automation_phases"
    def self.description = "Inspect a project's six automation phases, separate release and deployment controls, rollout state, and continuation grants."

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer", description: "The project ID" } }, required: [ "project_id" ] }
    end

    def perform(project_id:)
      Automation::PhaseSettings::Projection.call(project: project_for(project_id))
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
