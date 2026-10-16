# frozen_string_literal: true

module Tools
  # @spec FACET-CONFIDENCE-007
  class ListExplicitPreferences < BaseTool
    authorize :edit?, ->(_args) { current_user.settings }

    def self.tool_name = "list_explicit_preferences"

    def self.description
      "List the current user's explicitly stated preferences and their confirmed scopes."
    end

    def perform
      ExplicitPreference.for_owner(user).order(:created_at).map do |preference|
        preference.slice("id", "statement", "scope", "project_id", "feature_intent_id", "chat_session_id", "created_at", "updated_at")
      end
    end
  end
end
