# frozen_string_literal: true

module Tools
  # @spec FACET-CONFIDENCE-007
  class SaveExplicitPreference < BaseTool
    authorize :edit?, ->(_args) { current_user.settings }

    def self.tool_name = "save_explicit_preference"
    def self.write_operation? = true

    def self.description
      "Save or correct an explicitly stated user preference after the user confirms its statement and scope."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          statement: { type: "string", description: "The user's verbatim preference statement." },
          scope: { type: "string", enum: ExplicitPreference::SCOPES },
          project_id: { type: "integer", description: "Required only for project scope." },
          feature_intent_id: { type: "integer", description: "Required only for feature scope." },
          preference_id: { type: "integer", description: "Existing preference to correct." },
          confirmed: { type: "boolean", description: "True only after the user confirms the statement and scope." }
        },
        required: %w[statement scope confirmed]
      }
    end

    def perform(statement:, scope:, confirmed: false, project_id: nil, feature_intent_id: nil, preference_id: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to save an explicit preference" unless confirmed

      return update_preference(preference_id:, statement:) if preference_id.present?

      ExplicitPreferences::Persist.call(
        account: user.account,
        owner: user,
        actor: user,
        statement:,
        scope:,
        explicit: true,
        scope_confirmed: true,
        project: project_for(project_id),
        feature_intent: feature_intent_for(feature_intent_id),
        chat_session: session
      ).slice("id", "statement", "scope", "project_id", "feature_intent_id")
    end

    private

    def update_preference(preference_id:, statement:)
      preference = user.explicit_preferences.find(preference_id)
      ExplicitPreferences::Update.call(preference:, actor: user, statement:, explicit: true, scope_confirmed: true)
        .slice("id", "statement", "scope", "project_id", "feature_intent_id")
    end

    def project_for(project_id)
      return if project_id.blank?

      project = user.account.projects.find(project_id)
      authorize project, :update?, policy_class: ProjectPolicy
      project
    end

    def feature_intent_for(feature_intent_id)
      return if feature_intent_id.blank?

      feature_intent = FeatureIntent.joins(:project).where(projects: { account_id: user.account_id }).find(feature_intent_id)
      authorize feature_intent.project, :update?, policy_class: ProjectPolicy
      feature_intent
    end
  end
end
