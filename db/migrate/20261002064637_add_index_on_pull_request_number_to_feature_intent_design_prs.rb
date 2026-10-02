# frozen_string_literal: true

# Add a non-unique index on `feature_intent_design_prs.pull_request_number`
# so the webhook reconciliation query (`WHERE pull_request_number = ?`,
# called once per `pull_request` webhook for every project) is an index
# lookup instead of a sequential scan. The composite unique
# `[feature_intent_id, pull_request_number]` index cannot serve a
# `pull_request_number`-only predicate.
# @spec FEATURE-APPROVAL-017
class AddIndexOnPullRequestNumberToFeatureIntentDesignPrs < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless index_exists?(:feature_intent_design_prs, :pull_request_number)
      add_index :feature_intent_design_prs, :pull_request_number,
        algorithm: :concurrently,
        if_not_exists: true,
        name: "index_feature_intent_design_prs_on_pull_request_number"
    end
  end

  def down
    if index_exists?(:feature_intent_design_prs, :pull_request_number)
      remove_index :feature_intent_design_prs,
        name: "index_feature_intent_design_prs_on_pull_request_number",
        if_exists: true
    end
  end
end
