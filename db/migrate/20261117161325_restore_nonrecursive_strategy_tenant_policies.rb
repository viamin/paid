# frozen_string_literal: true

require_relative "20260511040425_fix_strategies_rls_infinite_recursion"

class RestoreNonrecursiveStrategyTenantPolicies < ActiveRecord::Migration[8.1]
  def up
    # Restore the final intended visibility, not recursive predicates captured
    # from a drifted catalog. Reference ownership belongs in persisted guards.
    # Policy replacement, read-only validation and FX guards commit together.
    safety_assured do
      FixStrategiesRlsInfiniteRecursion.new.up
      validate_reference_ownership!
      create_function :validate_strategy_current_version_reference
      create_trigger :validate_strategy_current_version_reference
      create_function :validate_strategy_version_parent_reference
      create_trigger :validate_strategy_version_parent_reference
    end
  end

  def down
    # Keep nonrecursive policies and ownership guards on rollback.
  end

  private

  def validate_reference_ownership!
    counts = with_system_access do
      [ invalid_current_versions, invalid_parent_versions ]
    end
    return if counts.all?(&:zero?)

    raise ActiveRecord::MigrationError,
      "Existing strategy reference ownership is invalid (current: #{counts.first}, parent: #{counts.last}); repair before migrating"
  end

  def with_system_access
    previous = select_value("SELECT current_setting('paid.bypass_tenant_rls', true)")
    execute "SELECT set_config('paid.bypass_tenant_rls', 'true', true)"
    yield
  ensure
    execute "SELECT set_config('paid.bypass_tenant_rls', #{connection.quote(previous.presence || 'false')}, true)"
  end

  def invalid_current_versions
    select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM strategies
      LEFT JOIN strategy_versions ON strategy_versions.id = strategies.current_version_id
      WHERE strategies.current_version_id IS NOT NULL
        AND (strategy_versions.id IS NULL OR strategy_versions.strategy_id <> strategies.id)
    SQL
  end

  def invalid_parent_versions
    select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM strategy_versions AS child
      LEFT JOIN strategy_versions AS parent ON parent.id = child.parent_version_id
      WHERE child.parent_version_id IS NOT NULL
        AND (parent.id IS NULL OR parent.strategy_id <> child.strategy_id)
    SQL
  end
end
