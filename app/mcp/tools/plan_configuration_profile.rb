# frozen_string_literal: true

module Tools
  class PlanConfigurationProfile < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "plan_configuration_profile"
    def self.write_operation? = false

    def self.description
      "Build a read-only before/after diff for applying a Paid configuration profile to a project."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          profile_id: { type: "string", description: "The configuration profile to plan" },
          project_id: { type: "integer", description: "The project to scope the plan to" }
        },
        required: %w[profile_id project_id]
      }
    end

    def perform(profile_id:, project_id:)
      project = project_for(project_id)
      profile = ConfigurationProfiles::Registry.find!(profile_id)
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)

      {
        profile_id: profile.key.to_s,
        project_id: project.id,
        label: plan.label,
        source: plan.source.to_s,
        changes: plan.changes.map { |change| { field: change.field.to_s, from: change.from, to: change.to } },
        applied_fields: plan.applied_fields.map(&:to_s)
      }
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end
  end
end
