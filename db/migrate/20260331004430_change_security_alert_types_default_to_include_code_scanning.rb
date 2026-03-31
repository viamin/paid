# frozen_string_literal: true

class ChangeSecurityAlertTypesDefaultToIncludeCodeScanning < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :security_alert_types, from: [ "dependabot" ], to: %w[dependabot code_scanning]
  end
end
