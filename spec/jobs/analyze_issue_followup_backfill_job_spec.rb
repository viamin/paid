# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyzeIssueFollowupBackfillJob do
  describe "#perform" do
    let(:project) do
      create(:project, auto_pick_enabled: true, auto_enhance_enabled: true)
    end
    let(:issue) do
      create(:issue, project: project, paid_state: "analyzed", github_state: "open", is_pull_request: false)
    end
    let!(:runner) { create(:runner, user: project.created_by) }

    before do
      Rails.cache.clear
    end

    it "queues a create_pr follow-up for analyzed issues with sufficient context" do
      analysis_run = create(:agent_run, :analyze_issue_goal, :completed, project: project, issue: issue, runner: runner)
      analysis_run.log!("stdout", { sufficient_context: true, reasoning: "ready", missing_context_areas: [] }.to_json)

      expect {
        described_class.perform_now
      }.to change {
        project.agent_runs.where(goal: "create_pr", status: "queued").count
      }.by(1)
    end

    it "queues an enhance_issue follow-up for analyzed issues without sufficient context" do
      analysis_run = create(:agent_run, :analyze_issue_goal, :completed, project: project, issue: issue, runner: runner)
      analysis_run.log!("stdout", { sufficient_context: false, reasoning: "needs details", missing_context_areas: [ "acceptance criteria" ] }.to_json)

      expect {
        described_class.perform_now
      }.to change {
        project.agent_runs.where(goal: "enhance_issue", status: "queued").count
      }.by(1)
    end

    it "skips issues without a parseable analysis payload" do
      analysis_run = create(:agent_run, :analyze_issue_goal, :completed, project: project, issue: issue, runner: runner)
      analysis_run.log!("stdout", "not json")

      expect {
        described_class.perform_now
      }.not_to change {
        project.agent_runs.where(status: "queued").count
      }
    end
  end
end
