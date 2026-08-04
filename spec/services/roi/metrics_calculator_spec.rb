# frozen_string_literal: true

require "rails_helper"

RSpec.describe Roi::MetricsCalculator do
  describe ".call" do
    it "excludes preview provisioning runs from array-backed summaries" do
      project = create(:project)
      issue = create(:issue, project:, github_created_at: 5.days.ago)
      accepted_run = create_accepted_run(project:, issue:)
      preview_run = create_preview_run(project:, issue:)

      stats = described_class.call(agent_runs: [ accepted_run, preview_run ], related_runs: [ accepted_run, preview_run ])

      expect(stats).to include(
        created_pr_count: 1,
        accepted_pr_count: 1,
        total_cost_cents: 6_000,
        cost_per_accepted_pr_cents: 6_000
      )
    end
  end

  def create_accepted_run(project:, issue:)
    run = create(:agent_run, :completed,
      project:,
      issue:,
      created_at: 4.days.ago,
      completed_at: 3.days.ago,
      cost_cents: 6_000,
      goal: "create_pr",
      pull_request_number: 11)
    create(:quality_metric, :human, agent_run: run, created_at: 2.days.ago, scores: { "pr_merged" => 1.0 })
    run
  end

  def create_preview_run(project:, issue:)
    run = create(:agent_run, :completed, :internal_agent,
      project:,
      issue:,
      created_at: 3.days.ago,
      completed_at: 2.days.ago,
      cost_cents: 20_000,
      goal: "create_pr",
      pull_request_number: 12,
      external_metadata: { "preview_session" => true })
    create(:quality_metric, :human, agent_run: run, created_at: 1.day.ago, scores: { "pr_merged" => 1.0 })
    run
  end
end
