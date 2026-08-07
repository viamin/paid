# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideAbTests::RecordResult do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:style_guide) { create(:style_guide, account: account, project: nil) }
  let(:style_guide_ab_test) do
    create(:style_guide_ab_test,
      account: account,
      style_guide: style_guide,
      control_version: style_guide.current_version,
      status: "running",
      started_at: Time.current)
  end
  let!(:control_variant) do
    create(:style_guide_ab_test_variant,
      style_guide_ab_test: style_guide_ab_test,
      style_guide_version: style_guide.current_version,
      is_control: true)
  end
  let!(:variant_version) do
    create(:style_guide_version,
      style_guide: style_guide,
      version: style_guide.current_version.version + 1,
      raw_content: "Variant rules")
  end
  let!(:variant) do
    create(:style_guide_ab_test_variant,
      style_guide_ab_test: style_guide_ab_test,
      style_guide_version: variant_version)
  end
  let(:agent_run) { create(:agent_run, project: project) }
  let!(:assignment) do
    create(:style_guide_ab_test_assignment,
      style_guide_ab_test: style_guide_ab_test,
      style_guide_ab_test_variant: variant,
      agent_run: agent_run)
  end

  def record_result(score, update_existing: false)
    described_class.call(
      style_guide_ab_test: style_guide_ab_test,
      agent_run: agent_run,
      quality_score: score,
      update_existing: update_existing
    )
  end

  def seed_control_score(score)
    control_run = create(:agent_run, project: project)
    create(:style_guide_ab_test_assignment,
      style_guide_ab_test: style_guide_ab_test,
      style_guide_ab_test_variant: control_variant,
      agent_run: control_run,
      quality_score: score)
    control_variant.update!(sample_count: 1, total_quality_score: score, avg_quality_score: score)
  end

  # @spec STYLE-GUIDE-EVOLUTION-011
  it "updates an existing score and adjusts aggregates when update_existing is true" do
    record_result(0.8)
    record_result(0.6, update_existing: true)

    expect(assignment.reload.quality_score.to_f).to eq(0.6)
    expect(variant.reload.sample_count).to eq(1)
    expect(variant.avg_quality_score.to_f).to eq(0.6)
  end

  it "clears stale cached analysis when update_existing replaces a score" do
    seed_control_score(0.7)
    record_result(0.8)
    style_guide_ab_test.update_columns(cached_analysis: { status: "stale" }, analysis_samples_key: "old")

    record_result(0.9, update_existing: true)

    expect(style_guide_ab_test.reload.cached_analysis).to be_nil
    expect(style_guide_ab_test.analysis_samples_key).to be_nil
  end
end
