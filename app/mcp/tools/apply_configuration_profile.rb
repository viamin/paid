# frozen_string_literal: true

module Tools
  class ApplyConfigurationProfile < BaseTool
    authorize :update?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "apply_configuration_profile"
    def self.write_operation? = true

    def self.description
      "Apply a Paid configuration profile to a project in one confirmed batch."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          profile_id: { type: "string", description: "The configuration profile to apply" },
          project_id: { type: "integer", description: "The project to apply the profile to" },
          confirmed: { type: "boolean" }
        },
        required: %w[profile_id project_id confirmed]
      }
    end

    def perform(profile_id:, project_id:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to apply a configuration profile" unless confirmed

      project = project_for(project_id)
      profile = ConfigurationProfiles::Registry.find!(profile_id)
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)
      result = ConfigurationProfiles::Applier.call(project, plan, actor: user)

      {
        profile_id: profile.key.to_s,
        project_id: project.id,
        applied_fields: result.changes.map { |change| change.field.to_s },
        activity_id: result.activity&.id
      }
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end
  end
end
