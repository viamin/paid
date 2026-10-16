# frozen_string_literal: true

module ExplicitPreferences
  # @spec FACET-CONFIDENCE-007 QUESTION-EXPLORATION-011
  class Persist
    def self.call(...) = new(...).call

    def initialize(account:, owner:, actor:, statement:, scope:, explicit:, scope_confirmed:, project: nil,
      feature_intent: nil, chat_session: nil)
      @account = account
      @owner = owner
      @actor = actor
      @statement = statement.to_s.strip
      @scope = scope.to_s
      @explicit = explicit
      @scope_confirmed = scope_confirmed
      @project = project
      @feature_intent = feature_intent
      @chat_session = chat_session
    end

    def call
      validate_confirmation!
      ExplicitPreference.create!(attributes)
    end

    private

    attr_reader :account, :actor, :chat_session, :explicit, :feature_intent, :owner, :project, :scope,
      :scope_confirmed, :statement

    def validate_confirmation!
      raise ArgumentError, "An explicit user statement is required" unless explicit
      raise ArgumentError, "An explicit or clarified scope is required" unless scope_confirmed
    end

    def attributes
      {
        account:,
        user: owner,
        recorded_by: actor,
        statement:,
        scope:,
        project: scoped_project,
        feature_intent: scoped_feature_intent,
        chat_session:
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
