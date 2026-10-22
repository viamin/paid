# frozen_string_literal: true

# @spec ISSUE-TREE-001
class AddIssueTreeReceiptToFeatureIntents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:feature_intents, :issue_tree_manifest)
      add_column :feature_intents, :issue_tree_manifest, :jsonb, null: false, default: {},
        comment: "Planned issue-tree receipt keyed by stable task identity, including expected relationships and qualified remote identities."
    end
    unless column_exists?(:feature_intents, :issue_tree_verification)
      add_column :feature_intents, :issue_tree_verification, :jsonb, null: false, default: {},
        comment: "Latest structural issue-tree verification result, revision, time, filing progress, and unresolved work."
    end

    # A verified implementation tree can intentionally serve more than one
    # design record. The receipt, rather than a unique issue ownership claim,
    # records that relationship.
    remove_index :feature_intent_issues, :issue_id if index_exists?(:feature_intent_issues, :issue_id, unique: true)
    add_index :feature_intent_issues, :issue_id, algorithm: :concurrently unless index_exists?(:feature_intent_issues, :issue_id)
  end
end
