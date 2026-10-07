# frozen_string_literal: true

# Re-enables Dependabot alert coverage scanning on existing projects after
# #619 stripped "dependabot" from `security_alert_types`. Mirrors the
# #619 removal in reverse: restores the column default to include
# "dependabot" and backfills existing rows so every project (current and
# newly created) can exercise DEPENDABOT-COVERAGE-001. Operators can still
# opt out per-project by editing the array, but the feature is no longer
# unreachable in production. @spec DEPENDABOT-COVERAGE-001
class RestoreDependabotAlertTypeDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :security_alert_types, %w[dependabot code_scanning]

    # Backfill existing projects: add "dependabot" if it is missing, keeping
    # any other alert types the project already enabled. The previous removal
    # (#619) defaulted empty arrays back to ["code_scanning"], so a row with
    # only ["code_scanning"] becomes ["dependabot","code_scanning"].
    safety_assured do
      execute <<~SQL.squish
        UPDATE projects
        SET security_alert_types = (
          SELECT jsonb_agg(DISTINCT elem)
          FROM jsonb_array_elements(security_alert_types || '["dependabot"]'::jsonb) AS elem
        )
        WHERE NOT (security_alert_types @> '["dependabot"]'::jsonb)
      SQL
    end
  end

  def down
    change_column_default :projects, :security_alert_types, [ "code_scanning" ]

    # Mirror the original #619 removal: strip "dependabot" from every row,
    # falling back to ["code_scanning"] when the array would otherwise empty.
    safety_assured do
      execute <<~SQL.squish
        UPDATE projects
        SET security_alert_types = CASE
          WHEN (
            SELECT COUNT(*)
            FROM jsonb_array_elements(security_alert_types) AS elem
            WHERE elem != '"dependabot"'::jsonb
          ) = 0
          THEN '["code_scanning"]'::jsonb
          ELSE (
            SELECT jsonb_agg(elem)
            FROM jsonb_array_elements(security_alert_types) AS elem
            WHERE elem != '"dependabot"'::jsonb
          )
        END
        WHERE security_alert_types @> '["dependabot"]'::jsonb
      SQL
    end
  end
end
