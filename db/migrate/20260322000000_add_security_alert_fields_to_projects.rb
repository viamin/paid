# frozen_string_literal: true

class AddSecurityAlertFieldsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_scan_security, :boolean, default: false, null: false
    add_column :projects, :security_severity_threshold, :string, default: "high", null: false
    add_column :projects, :security_alert_types, :jsonb, default: [ "dependabot" ], null: false
    add_column :projects, :max_security_fix_runs, :integer, default: 3, null: false
  end
end
