# frozen_string_literal: true

class NullifyHistoricalActorReferencesOnUserDeletion < ActiveRecord::Migration[8.1]
  def up
    change_column_null :issue_continuation_requests, :requested_by_id, true
    change_column_null :shared_delivery_evidence_associations, :authorized_by_id, true

    replace_foreign_key :issue_continuation_requests, :requested_by_id
    replace_foreign_key :shared_delivery_evidence_associations, :authorized_by_id
    permit_historical_shared_delivery_authorizer
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Nullified historical attribution cannot be reconstructed safely; use a reviewed forward migration."
  end

  private

  def replace_foreign_key(table, column)
    remove_foreign_key(table, column:)
    add_foreign_key(table, :users, column:, on_delete: :nullify, validate: false)
  end

  def permit_historical_shared_delivery_authorizer
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON shared_delivery_evidence_associations"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON shared_delivery_evidence_associations
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (
            paid_tenant_bypass() OR (
              account_id = paid_current_account_id()
              AND EXISTS (SELECT 1 FROM projects WHERE projects.id = shared_delivery_evidence_associations.project_id AND projects.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM issues INNER JOIN projects ON projects.id = issues.project_id WHERE issues.id = shared_delivery_evidence_associations.issue_id AND issues.project_id = shared_delivery_evidence_associations.project_id AND projects.account_id = paid_current_account_id())
              AND EXISTS (SELECT 1 FROM issues pull_requests INNER JOIN projects ON projects.id = pull_requests.project_id WHERE pull_requests.id = shared_delivery_evidence_associations.pull_request_id AND pull_requests.project_id = shared_delivery_evidence_associations.project_id AND projects.account_id = paid_current_account_id())
              AND (authorized_by_id IS NULL OR EXISTS (SELECT 1 FROM users WHERE users.id = shared_delivery_evidence_associations.authorized_by_id AND users.account_id = paid_current_account_id()))
            )
          );
      SQL
    end
  end
end
