# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::QueueAgentRunActivity do
  describe "performance follow-up evidence" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 42) }

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "snapshots the open finding's evidence onto the queued run" do
      finding = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "dashboard", actionable: true)

      described_class.new.execute(
        project_id: project.id,
        issue_id: issue.id,
        source_pull_request_number: 42,
        goal: "create_pr",
        focus: "performance_regression"
      )

      run = AgentRun.find_by(project: project, focus: "performance_regression")
      expect(run.external_metadata["page_load_regression"]).to include(
        "route_name" => "dashboard",
        "baseline_ms" => finding.baseline_ms,
        "current_ms" => finding.current_ms
      )
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "leaves metadata untouched for other focuses" do
      described_class.new.execute(
        project_id: project.id,
        issue_id: issue.id,
        source_pull_request_number: 42,
        goal: "create_pr",
        focus: "ci_fix"
      )

      run = AgentRun.find_by(project: project, focus: "ci_fix")
      expect(run.external_metadata["page_load_regression"]).to be_nil
    end
  end
end
