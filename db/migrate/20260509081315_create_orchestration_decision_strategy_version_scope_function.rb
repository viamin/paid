# frozen_string_literal: true

class CreateOrchestrationDecisionStrategyVersionScopeFunction < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION validate_orchestration_decision_strategy_version_scope()
      RETURNS trigger
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = public, pg_temp
      AS $$
      BEGIN
        IF NEW.strategy_version_id IS NULL THEN
          RETURN NEW;
        END IF;

        IF EXISTS (
          SELECT 1
          FROM strategy_versions
          INNER JOIN strategies ON strategies.id = strategy_versions.strategy_id
          WHERE strategy_versions.id = NEW.strategy_version_id
            AND (
              strategies.account_id IS NULL
              OR (
                strategies.account_id = paid_current_account_id()
                AND (
                  strategies.project_id IS NULL
                  OR strategies.project_id = NEW.project_id
                )
              )
            )
        ) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'strategy_version_id must reference a global or same-tenant strategy version';
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER validate_strategy_version_scope
      BEFORE INSERT OR UPDATE OF project_id, strategy_version_id ON orchestration_decisions
      FOR EACH ROW
      EXECUTE FUNCTION validate_orchestration_decision_strategy_version_scope();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS validate_strategy_version_scope ON orchestration_decisions"
    execute "DROP FUNCTION IF EXISTS validate_orchestration_decision_strategy_version_scope()"
  end
end
