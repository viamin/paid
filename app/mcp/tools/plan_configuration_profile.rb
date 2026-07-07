# frozen_string_literal: true

module Tools
  class PlanConfigurationProfile < BaseTool
    authorize :update?, ->(_args) { current_user.user_setting || UserSetting.new(user: current_user) }, policy_class: UserSettingPolicy

    def self.tool_name = "plan_configuration_profile"

    def self.description
      "Build a read-only before/after plan for applying a Paid configuration profile."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          profile_id: { type: "string", description: "The configuration profile to plan" },
          project_id: { type: "integer", description: "Optional project to scope the profile to" },
          overrides: { type: "object", description: "Optional declared profile overrides" }
        },
        required: [ "profile_id" ]
      }
    end

    def perform(profile_id:, project_id: nil, overrides: {})
      raise ArgumentError, "overrides must be an object" unless overrides.is_a?(Hash)

      profile = profile_for!(profile_id)
      project = resolved_project(project_id)
      plan = profile.build_plan(
        user:,
        project:,
        project_id: project&.id || project_id_for(project_id),
        overrides:
      )

      plan.to_h
    end

    private

    def profile_for!(profile_id)
      ConfigurationProfiles::Registry.find(profile_id) || raise(ArgumentError, "Unknown configuration profile: #{profile_id.inspect}")
    end

    def resolved_project(project_id)
      effective_project_id = project_id_for(project_id)
      return nil if effective_project_id.blank?

      project = policy_scope(Project).find(effective_project_id)
      authorize(project, :show?, policy_class: ProjectPolicy)
      project
    end

    def project_id_for(project_id)
      project_id || session&.project_id
    end
  end
end
