# frozen_string_literal: true

class FixStrategiesRlsInfiniteRecursion < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      drop_table_policies("strategies")
      recreate_strategies_policies

      drop_table_policies("strategy_versions")
      recreate_strategy_versions_policies
    end
  end

  def down
    safety_assured do
      drop_table_policies("strategies")
      recreate_strategies_policies_with_recursion("strategies")

      drop_table_policies("strategy_versions")
      recreate_strategies_policies_with_recursion("strategy_versions")
    end
  end

  private

  POLICY_NAMES = %w[
    tenant_isolation_select
    tenant_isolation_insert
    tenant_isolation_update
    tenant_isolation_delete
  ].freeze

  def drop_table_policies(table)
    POLICY_NAMES.each do |policy|
      execute "DROP POLICY IF EXISTS #{policy} ON #{quote_table_name(table)}"
    end
  end

  def recreate_strategies_policies
    read = strategy_scope_condition
    write = tenant_owned_strategy_condition("strategies")

    create_policies("strategies", read, write)
  end

  def recreate_strategy_versions_policies
    read = strategy_version_read_condition
    write = strategy_version_write_condition

    create_policies("strategy_versions", read, write)
  end

  def create_policies(table, read_condition, write_condition)
    qt = quote_table_name(table)

    execute <<~SQL
      CREATE POLICY tenant_isolation_select ON #{qt}
      AS PERMISSIVE FOR SELECT
      USING (paid_tenant_bypass() OR (#{read_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_insert ON #{qt}
      AS PERMISSIVE FOR INSERT
      WITH CHECK (paid_tenant_bypass() OR (#{write_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_update ON #{qt}
      AS PERMISSIVE FOR UPDATE
      USING (paid_tenant_bypass() OR (#{write_condition}))
      WITH CHECK (paid_tenant_bypass() OR (#{write_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_delete ON #{qt}
      AS PERMISSIVE FOR DELETE
      USING (paid_tenant_bypass() OR (#{write_condition}))
    SQL
  end

  def strategy_scope_condition
    "(strategies.account_id IS NULL OR #{tenant_owned_strategy_condition("strategies")})"
  end

  def tenant_owned_strategy_condition(table)
    <<~SQL.squish
      #{table}.account_id = paid_current_account_id()
      AND (
        #{table}.project_id IS NULL
        OR EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = #{table}.project_id
            AND projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def strategy_version_read_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM strategies
        WHERE strategies.id = strategy_versions.strategy_id
          AND (strategies.account_id IS NULL OR #{tenant_owned_strategy_condition("strategies")})
      )
    SQL
  end

  def strategy_version_write_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM strategies
        WHERE strategies.id = strategy_versions.strategy_id
          AND #{tenant_owned_strategy_condition("strategies")}
      )
      AND #{strategy_version_user_condition("created_by_user_id")}
      AND #{strategy_version_user_condition("promoted_by_user_id")}
    SQL
  end

  def strategy_version_user_condition(column)
    <<~SQL.squish
      (strategy_versions.#{column} IS NULL
       OR EXISTS (
         SELECT 1 FROM users
         WHERE users.id = strategy_versions.#{column}
           AND users.account_id = paid_current_account_id()
       ))
    SQL
  end

  def recreate_strategies_policies_with_recursion(table)
    case table
    when "strategies"
      create_policies("strategies",
        "(#{strategy_scope_condition} AND #{original_strategy_current_version_condition})",
        "(#{tenant_owned_strategy_condition('strategies')} AND #{original_strategy_current_version_condition})")
    when "strategy_versions"
      create_policies("strategy_versions",
        original_strategy_version_read_condition,
        original_strategy_version_write_condition)
    end
  end

  def original_strategy_current_version_condition
    <<~SQL.squish
      (strategies.current_version_id IS NULL
       OR EXISTS (
         SELECT 1 FROM strategy_versions
         WHERE strategy_versions.id = strategies.current_version_id
           AND strategy_versions.strategy_id = strategies.id
       ))
    SQL
  end

  def original_strategy_version_read_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM strategies
        WHERE strategies.id = strategy_versions.strategy_id
          AND (strategies.account_id IS NULL OR #{tenant_owned_strategy_condition("strategies")})
      )
    SQL
  end

  def original_strategy_version_write_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM strategies
        WHERE strategies.id = strategy_versions.strategy_id
          AND #{tenant_owned_strategy_condition("strategies")}
      )
      AND (strategy_versions.parent_version_id IS NULL
           OR EXISTS (
             SELECT 1 FROM strategy_versions parent_versions
             WHERE parent_versions.id = strategy_versions.parent_version_id
               AND parent_versions.strategy_id = strategy_versions.strategy_id
           ))
      AND #{strategy_version_user_condition("created_by_user_id")}
      AND #{strategy_version_user_condition("promoted_by_user_id")}
    SQL
  end
end
