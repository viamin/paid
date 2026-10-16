# frozen_string_literal: true

module ExplicitPreferences
  # Selects only preferences whose user and confirmed scope apply to the
  # current work. Contextual clarifying answers are deliberately excluded.
  # @spec FACET-CONFIDENCE-007
  class Context
    def self.call(...) = new(...).call

    def initialize(owner:, project: nil, feature_intent: nil)
      @owner = owner
      @project = project
      @feature_intent = feature_intent
    end

    def call
      ExplicitPreference.for_owner(owner).where(scope_conditions).order(:created_at)
    end

    private

    attr_reader :feature_intent, :owner, :project

    def scope_conditions
      conditions = [ "scope = 'user'" ]
      conditions << ExplicitPreference.sanitize_sql_array([ "scope = 'project' AND project_id = ?", project.id ]) if project
      conditions << ExplicitPreference.sanitize_sql_array([ "scope = 'feature' AND feature_intent_id = ?", feature_intent.id ]) if feature_intent
      conditions.join(" OR ")
    end
  end
end
