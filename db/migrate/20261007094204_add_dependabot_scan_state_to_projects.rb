class AddDependabotScanStateToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_dependabot_scan_at, :datetime,
      comment: "Timestamp of the most recent successful Dependabot alert scan. Uses code_scanning_interval_hours to limit polling."
    add_column :projects, :dependabot_permission_error_at, :datetime,
      comment: "Timestamp of the most recent Dependabot permissions error. Used to back off identical failures until credentials or repository settings change."
  end
end
