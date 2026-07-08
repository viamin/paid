# frozen_string_literal: true

module ConfigurationProfiles
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
  end
end
