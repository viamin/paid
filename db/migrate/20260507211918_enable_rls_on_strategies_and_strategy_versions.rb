# frozen_string_literal: true

class EnableRlsOnStrategiesAndStrategyVersions < ActiveRecord::Migration[8.1]
  def up
    %w[strategies strategy_versions].each { |table| drop_policies(table) }

    enable_read_write_policy("strategies", strategy_read_condition, strategy_write_condition)
    enable_read_write_policy("strategy_versions", strategy_version_read_condition, strategy_version_write_condition)
    restore_exception_incidents_policy
  end

  def down
    %w[strategies strategy_versions].each do |table|
      drop_policies(table)
      execute "ALTER TABLE #{quote_table_name(table)} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{quote_table_name(table)} DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def enable_read_write_policy(table, read_condition, write_condition)
    qualified_table = quote_table_name(table)

    execute "ALTER TABLE #{qualified_table} ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE #{qualified_table} FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation_select ON #{qualified_table}
      AS PERMISSIVE
      FOR SELECT
      USING (paid_tenant_bypass() OR (#{read_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_insert ON #{qualified_table}
      AS PERMISSIVE
      FOR INSERT
      WITH CHECK (paid_tenant_bypass() OR (#{write_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_update ON #{qualified_table}
      AS PERMISSIVE
      FOR UPDATE
      USING (paid_tenant_bypass() OR (#{write_condition}))
      WITH CHECK (paid_tenant_bypass() OR (#{write_condition}))
    SQL
    execute <<~SQL
      CREATE POLICY tenant_isolation_delete ON #{qualified_table}
      AS PERMISSIVE
      FOR DELETE
      USING (paid_tenant_bypass() OR (#{write_condition}))
    SQL
  end

  def drop_policies(table)
    qualified_table = quote_table_name(table)

    %w[
      tenant_isolation
      tenant_isolation_select
      tenant_isolation_insert
      tenant_isolation_update
      tenant_isolation_delete
    ].each do |policy|
      execute "DROP POLICY IF EXISTS #{policy} ON #{qualified_table}"
    end
  end

  def strategy_read_condition
    <<~SQL.squish
      #{strategy_scope_condition("strategies")}
      AND #{strategy_current_version_condition("strategies")}
    SQL
  end

  def strategy_write_condition
    <<~SQL.squish
      #{tenant_owned_strategy_condition("strategies")}
      AND #{strategy_current_version_condition("strategies")}
    SQL
  end

  def strategy_version_read_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM strategies
        WHERE strategies.id = strategy_versions.strategy_id
          AND #{strategy_scope_condition("strategies")}
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
      AND #{strategy_version_parent_condition}
      AND #{strategy_version_user_condition("created_by_user_id")}
      AND #{strategy_version_user_condition("promoted_by_user_id")}
    SQL
  end

  def strategy_scope_condition(table)
    "(#{table}.account_id IS NULL OR #{tenant_owned_strategy_condition(table)})"
  end

  def tenant_owned_strategy_condition(table)
    wrap_sql(<<~SQL.squish)
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

  def strategy_current_version_condition(table)
    wrap_sql(<<~SQL.squish)
      #{table}.current_version_id IS NULL
      OR EXISTS (
        SELECT 1 FROM strategy_versions
        WHERE strategy_versions.id = #{table}.current_version_id
          AND strategy_versions.strategy_id = #{table}.id
      )
    SQL
  end

  def strategy_version_parent_condition
    wrap_sql(<<~SQL.squish)
      strategy_versions.parent_version_id IS NULL
      OR EXISTS (
        SELECT 1 FROM strategy_versions parent_versions
        WHERE parent_versions.id = strategy_versions.parent_version_id
          AND parent_versions.strategy_id = strategy_versions.strategy_id
      )
    SQL
  end

  def strategy_version_user_condition(column)
    wrap_sql(<<~SQL.squish)
      strategy_versions.#{column} IS NULL
      OR EXISTS (
        SELECT 1 FROM users
        WHERE users.id = strategy_versions.#{column}
          AND users.account_id = paid_current_account_id()
      )
    SQL
  end

  def wrap_sql(sql)
    "(#{sql})"
  end

  def restore_exception_incidents_policy
    execute "DROP POLICY IF EXISTS tenant_isolation ON exception_incidents"
    execute "ALTER TABLE exception_incidents ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE exception_incidents FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON exception_incidents
      AS PERMISSIVE
      FOR ALL
      USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
      WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
    SQL
  end
end
