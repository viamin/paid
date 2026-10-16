# frozen_string_literal: true

module Tools
  # @spec FACET-CONFIDENCE-007
  class DeleteExplicitPreference < BaseTool
    authorize :edit?, ->(_args) { current_user.settings }

    def self.tool_name = "delete_explicit_preference"
    def self.write_operation? = true

    def self.description
      "Delete one of the current user's explicit preferences after confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          preference_id: { type: "integer" },
          confirmed: { type: "boolean" }
        },
        required: %w[preference_id confirmed]
      }
    end

    def perform(preference_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to delete an explicit preference" unless confirmed

      preference = user.explicit_preferences.find(preference_id)
      authorize_preference_target(preference)
      ExplicitPreferences::Delete.call(preference:)
      { deleted: true, preference_id: }
    end

    private

    def authorize_preference_target(preference)
      project = preference.project || preference.feature_intent&.project
      authorize project, :update?, policy_class: ProjectPolicy if project
    end
  end
end
