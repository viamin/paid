# frozen_string_literal: true

class ChangeSecurityAlertTypesDefaultToIncludeCodeScanning < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :security_alert_types, %w[dependabot code_scanning]

    # Backfill existing projects that still have the old default so CodeQL
    # scanning is enabled for everyone, not just newly-created projects.
    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = '["dependabot","code_scanning"]'::jsonb
      WHERE security_alert_types = '["dependabot"]'::jsonb
    SQL
  end

  def down
    change_column_default :projects, :security_alert_types, [ "dependabot" ]

    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = '["dependabot"]'::jsonb
      WHERE security_alert_types = '["dependabot","code_scanning"]'::jsonb
    SQL
  end
end
