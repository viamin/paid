# frozen_string_literal: true

class RemoveDependabotAlertFieldsFromProjects < ActiveRecord::Migration[8.1]
  def up
    remove_column :projects, :max_security_fix_runs

    # Remove "dependabot" from security_alert_types default, keeping only "code_scanning"
    change_column_default :projects, :security_alert_types, [ "code_scanning" ]

    # Backfill existing projects: remove "dependabot" from their security_alert_types.
    # The jsonb `-` operator with a text operand removes a key from an object, not
    # an element from an array. Use array filtering via subquery instead.
    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = (
        SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb)
        FROM jsonb_array_elements(security_alert_types) AS elem
        WHERE elem != '"dependabot"'::jsonb
      )
      WHERE security_alert_types @> '["dependabot"]'::jsonb
    SQL
  end

  def down
    add_column :projects, :max_security_fix_runs, :integer, default: 3, null: false

    change_column_default :projects, :security_alert_types, %w[dependabot code_scanning]

    # Re-add "dependabot" to any row that doesn't already contain it
    execute <<~SQL.squish
      UPDATE projects
      SET security_alert_types = security_alert_types || '["dependabot"]'::jsonb
      WHERE NOT security_alert_types @> '["dependabot"]'::jsonb
    SQL
  end
end
