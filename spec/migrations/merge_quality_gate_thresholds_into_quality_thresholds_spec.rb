# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260829222521_merge_quality_gate_thresholds_into_quality_thresholds")

RSpec.describe MergeQualityGateThresholdsIntoQualityThresholds, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:gate_class) { described_class::MigrationQualityGateThreshold }

  around do |example|
    ActiveRecord::Base.connection.create_table :quality_gate_thresholds do |t|
      t.bigint :project_id, null: false
      t.string :metric_key, null: false, limit: 50
      t.decimal :min_threshold, precision: 5, scale: 4
      t.decimal :max_threshold, precision: 5, scale: 4
      t.string :severity, null: false, default: "warning", limit: 20
      t.boolean :enabled, null: false, default: true
      t.jsonb :log_data
      t.timestamps
    end
    gate_class.reset_column_information

    example.run

    ActiveRecord::Base.connection.drop_table :quality_gate_thresholds
    gate_class.reset_column_information
  end

  it "preserves the source logidze history on the migrated threshold" do
    project = create(:project)
    history = { "v" => 2, "h" => [ { "v" => 1, "ts" => 1, "c" => { "enabled" => true } } ] }
    gate_class.create!(
      project_id: project.id,
      metric_key: "composite_score",
      min_threshold: 0.5,
      severity: "critical",
      enabled: true,
      log_data: history
    )

    migration.send(:migrate_gate_thresholds)

    threshold = QualityThreshold.find_by!(project: project, metric_type: "composite_score", goal_type: "all")
    # The logidze insert trigger appends its own snapshot entry, so assert the
    # original gate version survived rather than the log_data being wiped.
    preserved_version = threshold.log_data.versions.find { |version| version.version == 1 }
    expect(preserved_version.changes).to eq({ "enabled" => true })
  end
end
