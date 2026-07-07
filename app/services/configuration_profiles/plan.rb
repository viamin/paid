# frozen_string_literal: true

module ConfigurationProfiles
  # Immutable, serializable description of what applying a profile will change.
  # Built by +Profile.build_plan+ and consumed by +Applier.apply+. The plan
  # carries: per-level changes (key, before, after, attribute), prerequisites
  # (declarative conditions that must already be true), and clarifying
  # questions (open uncertainties to surface before confirmation).
  class Plan
    attr_reader :profile_id, :project_id, :changes, :prerequisites, :questions

    def initialize(profile_id:, project_id:, changes: [], prerequisites: [], questions: [])
      @profile_id = profile_id.to_s
      @project_id = project_id
      @changes = changes.freeze
      @prerequisites = prerequisites.freeze
      @questions = questions.freeze
      freeze
    end

    def levels
      changes.map { |change| change[:level] }.uniq
    end

    def changes_for(level)
      changes.select { |change| change[:level] == level.to_sym }
    end

    def to_h
      {
        profile_id: profile_id,
        project_id: project_id,
        levels: levels,
        changes: changes.map(&:dup),
        prerequisites: prerequisites.map(&:dup),
        questions: questions.map(&:dup)
      }
    end
  end
end
