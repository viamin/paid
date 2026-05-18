# frozen_string_literal: true

class EnableRlsOnKnowledgeRecommendations < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute "ALTER TABLE knowledge_recommendations ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE knowledge_recommendations FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON knowledge_recommendations
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = knowledge_recommendations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = knowledge_recommendations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON knowledge_recommendations"
      execute "ALTER TABLE knowledge_recommendations NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE knowledge_recommendations DISABLE ROW LEVEL SECURITY"
    end
  end
end
