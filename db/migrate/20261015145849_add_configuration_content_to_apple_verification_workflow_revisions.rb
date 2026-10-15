# frozen_string_literal: true

class AddConfigurationContentToAppleVerificationWorkflowRevisions < ActiveRecord::Migration[8.1]
  def change
    add_column :apple_verification_workflow_revisions, :configuration_content, :text,
      comment: "Committed Apple verification configuration bound to the workflow digest."
  end
end
