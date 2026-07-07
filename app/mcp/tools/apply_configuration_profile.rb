# frozen_string_literal: true

module Tools
  class ApplyConfigurationProfile < BaseTool
    authorize :update?, ->(_args) { current_user.user_setting || UserSetting.new(user: current_user) }, policy_class: UserSettingPolicy

    def self.tool_name = "apply_configuration_profile"
    def self.write_operation? = true

    def self.description
      "Apply a Paid configuration profile in one confirmed batch, optionally using a previously planned diff."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          profile_id: { type: "string", description: "The configuration profile to apply" },
          project_id: { type: "integer", description: "Optional project to scope the profile to" },
          overrides: { type: "object", description: "Optional declared profile overrides" },
          plan: { type: "object", description: "Optional serialized plan returned by plan_configuration_profile" },
          confirmed: { type: "boolean" }
        },
        required: %w[profile_id confirmed]
      }
    end

    def perform(profile_id:, confirmed:, project_id: nil, overrides: {}, plan: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to apply a configuration profile" unless confirmed
      raise ArgumentError, "overrides must be an object" unless overrides.is_a?(Hash)
      raise ArgumentError, "plan must be an object" if plan.present? && !plan.is_a?(Hash)

      serialized_plan = plan_payload_for(profile_id:, project_id:, overrides:, plan_payload: plan)
      applier_result = ConfigurationProfiles::Applier.call(
        plan: build_plan(serialized_plan),
        user:,
        project_id: serialized_plan[:project_id] || serialized_plan["project_id"]
      )

      applier_result.merge(plan: serialized_plan)
    rescue ConfigurationProfiles::Applier::UnmetPrerequisiteError => error
      {
        status: "blocked",
        error: "unmet_prerequisites",
        message: error.message,
        prerequisites: error.prerequisites,
        plan: serialized_plan
      }
    end

    private

    def plan_payload_for(profile_id:, project_id:, overrides:, plan_payload:)
      validate_plan_context!(profile_id:, project_id:, plan_payload:)
      build_fresh_plan(
        profile_id:,
        project_id:,
        overrides: effective_overrides(profile_id:, overrides:, plan_payload:)
      )
    end

    def build_fresh_plan(profile_id:, project_id:, overrides:)
      PlanConfigurationProfile.new(user:, session:).call(
        profile_id:,
        project_id:,
        overrides:
      ).deep_symbolize_keys
    end

    def validate_plan_context!(profile_id:, project_id:, plan_payload:)
      return if plan_payload.blank?

      if plan_payload[:profile_id].to_s != profile_id.to_s && plan_payload["profile_id"].to_s != profile_id.to_s
        raise ArgumentError, "plan profile_id does not match profile_id"
      end

      effective_project_id = project_id_for(project_id)
      return if effective_project_id.blank?

      planned_project_id = plan_payload[:project_id] || plan_payload["project_id"]
      raise ArgumentError, "plan project_id does not match project_id" if planned_project_id.to_i != effective_project_id.to_i
    end

    def effective_overrides(profile_id:, overrides:, plan_payload:)
      explicit_overrides = overrides.deep_symbolize_keys
      return explicit_overrides if plan_payload.blank?

      inferred_overrides = infer_overrides_from_plan(
        profile: ConfigurationProfiles::Registry.find(profile_id),
        plan_payload:
      )

      inferred_overrides.merge(explicit_overrides)
    end

    def infer_overrides_from_plan(profile:, plan_payload:)
      return {} if profile.blank?

      serialized_plan = plan_payload.deep_symbolize_keys
      changes = serialized_plan[:changes] || []

      profile.override_keys.each_with_object({}) do |key, inferred|
        matching_values = changes.filter_map do |change|
          next unless change[:attribute].to_s.split(".").last == key.to_s

          change[:after]
        end.uniq

        inferred[key] = matching_values.first if matching_values.one?
      end
    end

    def build_plan(serialized_plan)
      ConfigurationProfiles::Plan.new(
        profile_id: serialized_plan[:profile_id] || serialized_plan["profile_id"],
        project_id: serialized_plan[:project_id] || serialized_plan["project_id"],
        changes: serialized_plan[:changes] || serialized_plan["changes"] || [],
        prerequisites: serialized_plan[:prerequisites] || serialized_plan["prerequisites"] || [],
        questions: serialized_plan[:questions] || serialized_plan["questions"] || []
      )
    end

    def project_id_for(project_id)
      project_id || session&.project_id
    end
  end
end
