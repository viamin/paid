# frozen_string_literal: true

class SeedBaselineOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def up
    Strategies::SeedBaselineOrchestration.call
    backfill_baseline_strategy_versions
  end

  def down
    OrchestrationDecision.where(
      strategy_version_id: StrategyVersion.joins(:strategy)
        .where(strategies: { slug: baseline_slugs, account_id: nil, project_id: nil })
        .select(:id)
    ).update_all(strategy_version_id: nil)

    Strategy.global.where(slug: baseline_slugs).find_each(&:destroy!)
  end

  private

  def backfill_baseline_strategy_versions
    Strategies::BaselineOrchestration.definitions.each do |definition|
      version_id = Strategy.global
        .find_by!(slug: definition.fetch(:slug))
        .current_version_id

      OrchestrationDecision.where(
        decision_type: definition.fetch(:decision_type),
        strategy_version_id: nil
      ).update_all(strategy_version_id: version_id)
    end
  end

  def baseline_slugs
    Strategies::BaselineOrchestration.definitions.map { |definition| definition.fetch(:slug) }
  end
end
