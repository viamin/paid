# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideAbTests::Analyze do
  let(:account) { create(:account) }
  let(:style_guide) { create(:style_guide, account: account, project: nil) }
  let(:style_guide_ab_test) do
    create(:style_guide_ab_test,
      account: account,
      style_guide: style_guide,
      control_version: style_guide.current_version,
      status: "running",
      started_at: Time.current,
      min_samples_per_variant: 5)
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
  let(:project) { create(:project, account: account) }

  def add_scores(style_guide_ab_test:, project:, test_variant:, scores:)
    timestamp = Time.current
    agent_run_rows = scores.map do
      {
        project_id: project.id,
        issue_id: nil,
        agent_type: "claude_code",
        status: "pending",
        goal: "create_pr",
        trigger_type: "automatic",
        custom_prompt: "style guide experiment sample",
        proxy_token: SecureRandom.hex(32),
        created_at: timestamp,
        updated_at: timestamp
      }
    end

    inserted_runs = AgentRun.insert_all!(agent_run_rows, returning: %w[id])
    assignment_rows = scores.zip(inserted_runs.rows.flatten).map do |score, agent_run_id|
      {
        style_guide_ab_test_id: style_guide_ab_test.id,
        style_guide_ab_test_variant_id: test_variant.id,
        agent_run_id: agent_run_id,
        quality_score: score,
        created_at: timestamp,
        updated_at: timestamp
      }
    end

    StyleGuideAbTestAssignment.insert_all!(assignment_rows)
    test_variant.update!(sample_count: scores.size)
  end

  # @spec STYLE-GUIDE-EVOLUTION-013
  it "returns control_wins when every significant difference favors control" do
    add_scores(
      style_guide_ab_test: style_guide_ab_test,
      project: project,
      test_variant: control_variant,
      scores: [ 0.9, 0.91, 0.88, 0.92, 0.89, 0.9, 0.93, 0.87, 0.91, 0.9 ]
    )
    add_scores(
      style_guide_ab_test: style_guide_ab_test,
      project: project,
      test_variant: variant,
      scores: [ 0.3, 0.31, 0.29, 0.28, 0.32, 0.27, 0.3, 0.26, 0.31, 0.29 ]
    )

    result = described_class.call(style_guide_ab_test: style_guide_ab_test)

    expect(result.status).to eq(:control_wins)
    expect(result.winner).to be_nil
  end
end
