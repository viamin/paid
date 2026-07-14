# frozen_string_literal: true

class AddCodeScanningPermissionErrorAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :code_scanning_permission_error_at, :datetime,
      comment: "Timestamp of the most recent 403 (missing security_events/code_scanning_alerts:read " \
        "permission) hit while scanning for code scanning alerts. Used to back off retrying a scan " \
        "that will fail identically until a human fixes the token/App permission, without waiting the " \
        "full code_scanning_interval_hours window. Cleared on the next successful scan."
  end
end
