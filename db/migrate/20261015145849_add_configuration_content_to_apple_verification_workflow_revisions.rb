# frozen_string_literal: true

class AddConfigurationContentToAppleVerificationWorkflowRevisions < ActiveRecord::Migration[8.1]
  def up
    add_configuration_content
    disable_legacy_approved_revisions
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Cannot restore legacy approved workflow revisions disabled without their configuration content"
  end

  private

  def add_configuration_content
    return if column_exists?(:apple_verification_workflow_revisions, :configuration_content)

    add_column :apple_verification_workflow_revisions, :configuration_content, :text,
      comment: "Committed Apple verification configuration bound to the workflow digest."
  end

  def disable_legacy_approved_revisions
    # Legacy revisions retain only a digest, so their approved content cannot
    # be reconstructed safely. Disable them rather than admitting attempts
    # that cannot derive an approved guest manifest; the next sync creates a
    # draft that an administrator can approve.
    execute <<~SQL
      UPDATE apple_verification_workflow_revisions
      SET status = 'disabled', updated_at = CURRENT_TIMESTAMP
      WHERE status = 'approved' AND configuration_content IS NULL
    SQL
  end
end
