# frozen_string_literal: true

class RemoveDependabotAlertFieldsFromProjects < ActiveRecord::Migration[8.1]
  def up
    remove_column :projects, :max_security_fix_runs

    # Remove "dependabot" from security_alert_types default, keeping only "code_scanning"
    change_column_default :projects, :security_alert_types, ["code_scanning"]

    # Backfill existing projects: remove "dependabot" from their security_alert_types
    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = (security_alert_types - '"dependabot"')
      WHERE security_alert_types @> '"dependabot"'::jsonb
    SQL
  end

  def down
    add_column :projects, :max_security_fix_runs, :integer, default: 3, null: false

    change_column_default :projects, :security_alert_types, %w[dependabot code_scanning]

    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = '["dependabot","code_scanning"]'::jsonb
      WHERE security_alert_types = '["code_scanning"]'::jsonb
    SQL
  end
end
