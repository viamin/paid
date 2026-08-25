# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::QueueAgentRunActivity do
  describe "performance follow-up evidence" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 42) }

    def queue_run(**overrides)
      described_class.new.execute(
        {
          project_id: project.id,
          issue_id: issue.id,
          source_pull_request_number: 42,
          goal: "create_pr"
        }.merge(overrides)
      )
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "snapshots the open finding's evidence onto the queued run" do
      finding = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "dashboard", actionable: true)

      queue_run(focus: "performance_regression")

      run = AgentRun.find_by(project: project, focus: "performance_regression")
      expect(run.external_metadata["page_load_regression"]).to include(
        "route_name" => "dashboard",
        "baseline_ms" => finding.baseline_ms,
        "current_ms" => finding.current_ms
      )
    end

    # @spec PAGE-LOAD-FOLLOWUP-006
    it "counts an attempt against the finding it queued for" do
      finding = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, actionable: true)

      queue_run(focus: "performance_regression")

      expect(finding.reload.followup_attempts).to eq(1)
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "leaves metadata untouched for other focuses" do
      queue_run(focus: "ci_fix")

      run = AgentRun.find_by(project: project, focus: "ci_fix")
      expect(run.external_metadata["page_load_regression"]).to be_nil
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    # When the scanner threads the trigger evidence through, the queued run is
    # tied to the exact route the trigger pointed at rather than the most
    # recently updated actionable finding. With two open findings on the same
    # PR, ordering by updated_at would otherwise shift attribution if a newer
    # capture updated the wrong route first.
    it "binds the queued run to the finding whose route_name the evidence names" do
      dashboard = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "dashboard",
        baseline_ms: 640, current_ms: 1_100, delta_ms: 460, actionable: true)
      _settings = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "settings",
        baseline_ms: 200, current_ms: 900, delta_ms: 700, actionable: true,
        followup_attempts: PageLoadRegressionFinding::MAX_FOLLOWUP_ATTEMPTS - 1,
        updated_at: 1.minute.from_now)

      queue_run(focus: "performance_regression", focus_evidence: dashboard.evidence)

      run = AgentRun.find_by(project: project, focus: "performance_regression")
      expect(run.external_metadata["page_load_regression"]).to include(
        "route_name" => "dashboard",
        "baseline_ms" => 640,
        "current_ms" => 1_100
      )
      expect(dashboard.reload.followup_attempts).to eq(1)
    end

    # @spec PAGE-LOAD-FOLLOWUP-006
    # Without evidence threaded through, the activity falls back to the most
    # recently updated actionable finding — preserving the prior behavior when
    # a caller (e.g. an out-of-band manual queue) does not provide evidence.
    it "falls back to the most recently updated actionable finding when no evidence is provided" do
      _stale = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "dashboard",
        baseline_ms: 640, current_ms: 1_100, delta_ms: 460, actionable: true)
      newer = create(:page_load_regression_finding,
        project: project, pull_request_number: 42, route_name: "settings",
        baseline_ms: 200, current_ms: 900, delta_ms: 700, actionable: true,
        updated_at: 1.minute.from_now)

      queue_run(focus: "performance_regression")

      run = AgentRun.find_by(project: project, focus: "performance_regression")
      expect(run.external_metadata["page_load_regression"]).to include("route_name" => "settings")
      expect(newer.reload.followup_attempts).to eq(1)
    end
  end
end
