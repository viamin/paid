# frozen_string_literal: true

# Consolidates the project-only quality-gate threshold model into the
# account/project quality threshold model (issue #3514). Gate thresholds
# do not apply to a specific goal, so they are migrated onto the reserved
# QualityThreshold::ALL_GOALS ("all") goal_type sentinel.
class MergeQualityGateThresholdsIntoQualityThresholds < ActiveRecord::Migration[8.1]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  class MigrationQualityThreshold < ApplicationRecord
    self.table_name = "quality_thresholds"
  end

  class MigrationQualityGateThreshold < ApplicationRecord
    self.table_name = "quality_gate_thresholds"
  end

  class MigrationQualityGateEvent < ApplicationRecord
    self.table_name = "quality_gate_events"
  end

  GATE_GOAL_TYPE = "all"

  def up
    add_column :quality_thresholds, :max_value, :decimal, precision: 5, scale: 4,
      comment: "Upper bound whose breach triggers the gate for metrics where too high is bad."
    add_column :quality_thresholds, :severity, :string, limit: 20, null: false, default: "warning",
      comment: "Severity assigned when the threshold is breached: info, warning, or critical."
    change_column_null :quality_thresholds, :min_value, true

    safety_assured { add_reference :quality_gate_events, :quality_threshold, foreign_key: true, index: true }

    migrate_gate_thresholds
    migrate_gate_events

    safety_assured do
      change_column_null :quality_gate_events, :quality_threshold_id, false
      remove_reference :quality_gate_events, :quality_gate_threshold, foreign_key: true, index: true
      drop_table :quality_gate_thresholds
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def migrate_gate_thresholds
    MigrationQualityGateThreshold.find_each do |gate|
      project = MigrationProject.find(gate.project_id)

      MigrationQualityThreshold.find_or_create_by!(
        project_id: gate.project_id,
        metric_type: gate.metric_key,
        goal_type: GATE_GOAL_TYPE
      ) do |threshold|
        threshold.account_id = project.account_id
        threshold.min_value = gate.min_threshold
        threshold.max_value = gate.max_threshold
        threshold.severity = gate.severity
        threshold.enabled = gate.enabled
        threshold.log_data = gate.log_data
        threshold.created_at = gate.created_at
        threshold.updated_at = gate.updated_at
      end
    end
  end

  def migrate_gate_events
    MigrationQualityGateEvent.find_each do |event|
      gate = MigrationQualityGateThreshold.find(event.quality_gate_threshold_id)
      threshold = MigrationQualityThreshold.find_by!(
        project_id: gate.project_id, metric_type: gate.metric_key, goal_type: GATE_GOAL_TYPE
      )

      event.update!(quality_threshold_id: threshold.id)
    end
  end
end
