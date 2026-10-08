# frozen_string_literal: true

class AddUncoveredSinceToDependabotAlertCoverages < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:dependabot_alert_coverages, :uncovered_since)

    add_column :dependabot_alert_coverages, :uncovered_since, :datetime,
      comment: "When the alert most recently transitioned from an effective remediation " \
               "to an uncovered state; nil while the alert is covered. Drives the " \
               "seven-day escalation grace check after a remediation PR closes unmerged."
  end

  def down
    return unless column_exists?(:dependabot_alert_coverages, :uncovered_since)

    remove_column :dependabot_alert_coverages, :uncovered_since
  end
end
