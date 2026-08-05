# frozen_string_literal: true

module Tools
  # @spec CONFIG-PROFILES-003
  class PlanConfigurationProfile < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

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
          project_id: { type: "integer", description: "The project to scope the plan to" },
          overrides: { type: "object", description: "Optional answers to the profile's clarifying questions" }
        },
        required: %w[profile_id project_id]
      }
    end

    def perform(profile_id:, project_id:, overrides: {})
      project = project_for(project_id)
      profile = Configuration::Profiles::Registry.fetch(profile_id)
      plan = Configuration::Profiles::Planner.call(profile:, project:, overrides:, actor: user)

      {
        profile_id: profile.name,
        profile_name: profile.display_name,
        project_id: project.id,
        changes: plan.changes.map { |change| { key: change.key, from: change.from, to: change.to, level: change.level.to_s } },
        blocked: plan.blocked?,
        no_op: plan.no_op?,
        skipped_levels: plan.skipped_levels,
        unmet_prerequisites: plan.unmet_prerequisites,
        applied_overrides: plan.applied_overrides
      }
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end
  end
end
