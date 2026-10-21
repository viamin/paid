# frozen_string_literal: true

class AddConfidenceDeliveryReleaseTrackingToFeatureIntentIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :feature_intent_issues, :readiness_mapping, :jsonb, null: false, default: {}, comment: "Agent-authored current scope, facet prerequisites, and relevant design baseline for confidence delivery." unless column_exists?(:feature_intent_issues, :readiness_mapping)
    add_column :feature_intent_issues, :release_snapshot, :jsonb, null: false, default: {}, comment: "Immutable readiness evidence recorded when Paid releases the workflow-owned planning hold." unless column_exists?(:feature_intent_issues, :release_snapshot)
    add_column :feature_intent_issues, :release_state, :string, null: false, default: "held", comment: "Confidence-delivery projection state: held, pending, released, or reconciliation_failed." unless column_exists?(:feature_intent_issues, :release_state)
    add_column :feature_intent_issues, :released_at, :datetime, comment: "When the workflow-owned planning hold was reconciled successfully." unless column_exists?(:feature_intent_issues, :released_at)
    add_column :feature_intent_issues, :release_error, :text, comment: "Most recent GitHub planning-hold reconciliation failure, retained for visible retry." unless column_exists?(:feature_intent_issues, :release_error)
    add_index :feature_intent_issues, :release_state, algorithm: :concurrently unless index_exists?(:feature_intent_issues, :release_state)
  end

  def down
    remove_index :feature_intent_issues, :release_state, algorithm: :concurrently, if_exists: true
    remove_column :feature_intent_issues, :release_error if column_exists?(:feature_intent_issues, :release_error)
    remove_column :feature_intent_issues, :released_at if column_exists?(:feature_intent_issues, :released_at)
    remove_column :feature_intent_issues, :release_state if column_exists?(:feature_intent_issues, :release_state)
    remove_column :feature_intent_issues, :release_snapshot if column_exists?(:feature_intent_issues, :release_snapshot)
    remove_column :feature_intent_issues, :readiness_mapping if column_exists?(:feature_intent_issues, :readiness_mapping)
  end
end
