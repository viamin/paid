# frozen_string_literal: true

class EnableRlsOnStrategyExperimentTables < ActiveRecord::Migration[8.1]
  def up
    # strategy_experiments: direct account_id
    execute <<~SQL
      ALTER TABLE strategy_experiments ENABLE ROW LEVEL SECURITY;
      ALTER TABLE strategy_experiments FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON strategy_experiments
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR (strategy_experiments.account_id = paid_current_account_id()))
        WITH CHECK (paid_tenant_bypass() OR (strategy_experiments.account_id = paid_current_account_id()));
    SQL

    # strategy_experiment_variants: through strategy_experiment
    execute <<~SQL
      ALTER TABLE strategy_experiment_variants ENABLE ROW LEVEL SECURITY;
      ALTER TABLE strategy_experiment_variants FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON strategy_experiment_variants
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM strategy_experiments
            WHERE strategy_experiments.id = strategy_experiment_variants.strategy_experiment_id
              AND strategy_experiments.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM strategy_experiments
            WHERE strategy_experiments.id = strategy_experiment_variants.strategy_experiment_id
              AND strategy_experiments.account_id = paid_current_account_id()
          )
        );
    SQL

    # strategy_experiment_assignments: through strategy_experiment
    execute <<~SQL
      ALTER TABLE strategy_experiment_assignments ENABLE ROW LEVEL SECURITY;
      ALTER TABLE strategy_experiment_assignments FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON strategy_experiment_assignments
        AS PERMISSIVE FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM strategy_experiments
            WHERE strategy_experiments.id = strategy_experiment_assignments.strategy_experiment_id
              AND strategy_experiments.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM strategy_experiments
            WHERE strategy_experiments.id = strategy_experiment_assignments.strategy_experiment_id
              AND strategy_experiments.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def down
    %w[strategy_experiments strategy_experiment_variants strategy_experiment_assignments].each do |table|
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
