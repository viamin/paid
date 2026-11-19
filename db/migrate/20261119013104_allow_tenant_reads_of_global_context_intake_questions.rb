class AllowTenantReadsOfGlobalContextIntakeQuestions < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-001 POSTGRESQL-PERSISTENCE-006
  def up
    safety_assured do
      execute <<~SQL
        CREATE POLICY tenant_isolation_global_catalog_read ON context_intake_questions
          FOR SELECT
          USING (project_id IS NULL)
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation_global_catalog_read ON context_intake_questions"
    end
  end
end
