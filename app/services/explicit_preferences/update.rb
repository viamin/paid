# frozen_string_literal: true

module ExplicitPreferences
  # @spec FACET-CONFIDENCE-007
  class Update
    def self.call(...) = new(...).call

    def initialize(preference:, actor:, statement:, scope:, explicit:, scope_confirmed:, project: nil, feature_intent: nil)
      @preference = preference
      @actor = actor
      @statement = statement.to_s.strip
      @scope = scope.to_s
      @explicit = explicit
      @scope_confirmed = scope_confirmed
      @project = project
      @feature_intent = feature_intent
    end

    def call
      validate_confirmation!
      preference.update!(attributes)
      preference
    end

    private

    attr_reader :actor, :explicit, :feature_intent, :preference, :project, :scope, :scope_confirmed, :statement

    def validate_confirmation!
      raise ArgumentError, "An explicit user statement is required" unless explicit
      raise ArgumentError, "An explicit or clarified scope is required" unless scope_confirmed
    end

    def attributes
      {
        statement:,
        scope:,
        project: scoped_project,
        feature_intent: scoped_feature_intent,
        recorded_by: actor
      }
    end

    def scoped_project
      return project unless scope == "feature" && project.blank?

      feature_intent&.project
    end

    def scoped_feature_intent
      feature_intent
    end
  end
end
