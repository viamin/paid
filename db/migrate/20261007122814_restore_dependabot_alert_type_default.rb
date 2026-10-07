# frozen_string_literal: true

# Restores Dependabot alert coverage scanning for new rows by reverting the
# column default that #619 (`remove_dependabot_alert_fields_from_projects`)
# set to `["code_scanning"]`. Newly created projects once again receive
# `["dependabot", "code_scanning"]` so DEPENDABOT-COVERAGE-001 is no longer
# unreachable for fresh installs.
#
# We deliberately do NOT backfill existing rows. After #619 every project
# has `security_alert_types = ["code_scanning"]`, but that single value
# collapses three pre-#619 states we cannot tell apart:
#
#   * a project that enabled Dependabot (now stripped)
#   * a project that opted out of Dependabot (operator-set `["code_scanning"]`)
#   * a project created after #619 with the post-removal default
#
# Re-adding `"dependabot"` to every row with `["code_scanning"]` would
# silently override explicit operator opt-outs — projects would start
# hitting the Dependabot API and emitting coverage-failure notifications
# despite `scan_dependabot_alerts` being the documented opt-out path
# (`app/temporal/activities/scan_security_alerts_activity.rb:122-123`,
# exercised by `spec/temporal/activities/scan_security_alerts_activity_spec.rb:204`).
#
# Projects that want Dependabot coverage back after #619 opt in by editing
# the per-project `security_alert_types` array. That preserves the contract
# that the array is the operator's opt-out lever.
# @spec DEPENDABOT-COVERAGE-001
class RestoreDependabotAlertTypeDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :security_alert_types, %w[dependabot code_scanning]
  end

  def down
    change_column_default :projects, :security_alert_types, [ "code_scanning" ]
  end
end
