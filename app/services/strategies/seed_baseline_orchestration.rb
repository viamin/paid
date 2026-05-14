# frozen_string_literal: true

module Strategies
  class SeedBaselineOrchestration
    BASELINE_PROVENANCE_SOURCE = "baseline_workflow_extraction"
    SEED_CHANGE_REASONING = "Extracted from current hardcoded workflow defaults without semantic changes."
    SEED_CHANGE_NOTES = "Baseline strategy version seeded from runtime behavior."

    def self.call
      new.call
    end

    def call
      TenantContext.with_system_access do
        Strategies::BaselineOrchestration.definitions.map do |definition|
          seed_definition(definition)
        end
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

      strategy.with_lock do
        current_version = strategy.reload.current_version
        return strategy if current_version_matches_definition?(current_version, definition)

        promoted_at = Time.current
        version = strategy.create_version!(
          content: definition.fetch(:content),
          provenance: baseline_provenance(definition),
          promotion_state: "active",
          created_by: "seed",
          reasoning: SEED_CHANGE_REASONING,
          change_notes: SEED_CHANGE_NOTES,
          promoted_at: promoted_at
        )
        current_version&.update!(
          promotion_state: "retired",
          retired_at: promoted_at
        )
        strategy.update!(current_version: version)
      end

      strategy
    end

    def current_version_matches_definition?(current_version, definition)
      current_version&.active? &&
        current_version.content == definition.fetch(:content) &&
        current_version.provenance == baseline_provenance(definition)
    end

    def baseline_provenance(definition)
      {
        "source" => BASELINE_PROVENANCE_SOURCE,
        "decision_type" => definition.fetch(:decision_type)
      }
    end
  end
end
