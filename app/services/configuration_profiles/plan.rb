# frozen_string_literal: true

module ConfigurationProfiles
<<<<<<< HEAD
  # An ordered, human-described bundle of {Change} transitions meant to be
  # applied together to a single target.
  #
  # +source+ tags what produced the plan (e.g. +:configuration_profile+,
  # +:quality_gate_bundle+, +:cost_budget_preset+) and +reference+ optionally
  # carries the originating object (a {Profile}, a bundle id, etc.) so an
  # applier can record provenance in activity metadata without the generic
  # plan knowing what that object is.
  class Plan < Data.define(:label, :source, :changes, :reference)
    def initialize(label:, source:, changes:, reference: nil)
      changes = changes.map { |change| change.is_a?(Change) ? change : Change.new(**change) }
      super
    end

    def empty? = changes.empty?

    def size = changes.length

    # Returns a new plan whose changes are the reverse of these (each
    # +to+/+from+ swapped). Used to undo an applied plan.
    def reverser(label: "Revert: #{self.label}")
      self.class.new(label: label, source: source, reference: reference, changes: changes.map(&:reverser))
    end

    def applied_fields = changes.map(&:field)
=======
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
>>>>>>> origin/main
  end
end
