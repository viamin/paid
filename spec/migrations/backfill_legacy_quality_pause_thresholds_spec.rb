# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421110831_backfill_legacy_quality_pause_thresholds")

RSpec.describe BackfillLegacyQualityPauseThresholds, :aggregate_failures do
  let(:migration) { described_class.new }

  it "creates project composite thresholds from persisted legacy settings" do
    project = create(:project, review_settings: { "quality_pause_threshold" => 0.72 })

    migration.up

    threshold = QualityThreshold.find_by!(project: project, metric_type: "composite_score", goal_type: "create_pr")
    expect(threshold.account).to eq(project.account)
    expect(threshold.min_value).to eq(0.72)
    expect(threshold.enabled?).to be(true)
  end

  it "keeps existing project thresholds when legacy settings are present" do
    project = create(:project, review_settings: { "quality_pause_threshold" => 0.72 })
    existing = create(:quality_threshold, :project_override,
      project: project,
      metric_type: "composite_score",
      goal_type: "create_pr",
      min_value: 0.9)

    migration.up

    expect(existing.reload.min_value).to eq(0.9)
    expect(QualityThreshold.where(project: project, metric_type: "composite_score", goal_type: "create_pr").count).to eq(1)
  end

  it "skips invalid legacy settings" do
    invalid_project = create(:project, review_settings: { "quality_pause_threshold" => "high" })
    out_of_range_project = create(:project, review_settings: { "quality_pause_threshold" => 1.5 })

    migration.up

    expect(QualityThreshold.where(project: invalid_project)).to be_empty
    expect(QualityThreshold.where(project: out_of_range_project)).to be_empty
  end
end
