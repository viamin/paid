# frozen_string_literal: true

module Strategies
  class SeedBaselineOrchestration
    def self.call
      new.call
    end

    def call
      Strategies::BaselineOrchestration.definitions.map do |definition|
        seed_definition(definition)
      end
    end

    private

    def seed_definition(definition)
      strategy = Strategy.global.find_or_initialize_by(slug: definition.fetch(:slug))
      strategy.assign_attributes(
        name: definition.fetch(:name),
        description: definition.fetch(:description),
        decision_type: definition.fetch(:decision_type),
        status: "active",
        selection_rules: definition.fetch(:selection_rules)
      )
      strategy.save! if strategy.changed?

      return strategy if strategy.current_version.present?

      version = strategy.create_version!(
        content: definition.fetch(:content),
        provenance: {
          "source" => "baseline_workflow_extraction",
          "decision_type" => definition.fetch(:decision_type)
        },
        promotion_state: "active",
        created_by: "seed",
        reasoning: "Extracted from current hardcoded workflow defaults without semantic changes.",
        change_notes: "Initial baseline strategy version seeded from runtime behavior.",
        promoted_at: Time.current
      )
      strategy.update!(current_version: version)
      strategy
    end
  end
end
