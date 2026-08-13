# frozen_string_literal: true

class SeedBaselineOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def up
    TenantContext.with_system_access do
      Strategies::SeedBaselineOrchestration.call
      backfill_baseline_strategy_versions
    end
  end

  def down
    TenantContext.with_system_access do
      clear_backfilled_strategy_versions

      Strategy.global.where(slug: baseline_slugs).find_each(&:destroy!)
    end
  end

  private

  def backfill_baseline_strategy_versions
    return unless table_exists?(:orchestration_decisions)

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

  def clear_backfilled_strategy_versions
    return unless table_exists?(:orchestration_decisions)

    OrchestrationDecision.where(
      strategy_version_id: StrategyVersion.joins(:strategy)
        .where(strategies: { slug: baseline_slugs, account_id: nil, project_id: nil })
        .select(:id)
    ).update_all(strategy_version_id: nil)
  end

  def baseline_slugs
    Strategies::BaselineOrchestration.definitions.map { |definition| definition.fetch(:slug) }
  end
end
