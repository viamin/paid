# frozen_string_literal: true

class AddLastScannedHeadShaToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :last_scanned_head_sha, :string, limit: 40,
      comment: "PR HEAD commit SHA recorded by the most recent PR scan pass. Lets scan-time and " \
        "Inbox-time consumers (e.g. intent-conformance verdict lookups) identify the current HEAD " \
        "without an extra GitHub API call outside the scan cycle."
  end
end
