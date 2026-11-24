# frozen_string_literal: true

class EnableTenantRlsOnSharedDeliveryEvidenceAssociations < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        ALTER TABLE shared_delivery_evidence_associations ENABLE ROW LEVEL SECURITY;
        ALTER TABLE shared_delivery_evidence_associations FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON shared_delivery_evidence_associations
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR account_id = paid_current_account_id()
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              account_id = paid_current_account_id()
              AND EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = shared_delivery_evidence_associations.project_id
                  AND projects.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM issues
                INNER JOIN projects ON projects.id = issues.project_id
                WHERE issues.id = shared_delivery_evidence_associations.issue_id
                  AND issues.project_id = shared_delivery_evidence_associations.project_id
                  AND projects.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM issues pull_requests
                INNER JOIN projects ON projects.id = pull_requests.project_id
                WHERE pull_requests.id = shared_delivery_evidence_associations.pull_request_id
                  AND pull_requests.project_id = shared_delivery_evidence_associations.project_id
                  AND projects.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM users
                WHERE users.id = shared_delivery_evidence_associations.authorized_by_id
                  AND users.account_id = paid_current_account_id()
              )
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON shared_delivery_evidence_associations"
      execute "ALTER TABLE shared_delivery_evidence_associations NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE shared_delivery_evidence_associations DISABLE ROW LEVEL SECURITY"
    end
  end
end
