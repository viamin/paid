# frozen_string_literal: true

class AddMergePermissionRejectionToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :merge_permission_rejected_at, :datetime,
      comment: "When non-null, the most recent auto-merge attempt was rejected " \
               "by GitHub because the App installation token lacks a required " \
               "permission (e.g. `workflows` for a change under .github/workflows/). " \
               "Such rejections are permanent until the App's permissions change, so " \
               "this timestamp gates a retry cooldown instead of re-attempting every " \
               "poll cycle."
    add_column :issues, :merge_permission_rejection_reason, :text,
      comment: "Raw error message from the most recent merge-time GitHub App " \
               "permission rejection, for operator visibility."
  end
end
