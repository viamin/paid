# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanPaidPrsActivity do
    describe "page load regression triggers" do
    let(:activity) { described_class.new }
    let(:project) do
      create(:project, screenshot_settings: {
        "enabled" => true,
        "performance" => { "enabled" => true, "followup_enabled" => true }
      })
    end
    let(:issue) { create(:issue, :pull_request, project: project, github_number: 42) }

    def finding(**overrides)
      create(:page_load_regression_finding,
        project: project, pull_request_number: 42, **overrides)
    end

    # @spec PAGE-LOAD-FOLLOWUP-001
    it "emits a page_load_regression trigger for an actionable open finding" do
      finding(route_name: "dashboard", actionable: true)

      triggers = activity.send(:page_load_regression_triggers, project, issue)

      expect(triggers.map { |t| t[:type] }).to eq([ "page_load_regression" ])
      expect(triggers.first[:details]).to include("dashboard")
    end

    # @spec PAGE-LOAD-FOLLOWUP-002
    it "emits nothing when the project has not enabled performance follow-up runs" do
      project.update!(screenshot_settings: project.screenshot_settings.deep_merge(
        "performance" => { "followup_enabled" => false }
      ))
      finding(actionable: true)

      expect(activity.send(:page_load_regression_triggers, project.reload, issue)).to be_empty
    end

    # @spec PAGE-LOAD-FOLLOWUP-003
    it "emits nothing for a finding on a route the pull request did not touch" do
      finding(actionable: false)

      expect(activity.send(:page_load_regression_triggers, project, issue)).to be_empty
    end

    # @spec PAGE-LOAD-REGRESSION-006
    it "emits nothing once the finding is resolved" do
      finding(actionable: true, status: "resolved", resolved_at: Time.current)

      expect(activity.send(:page_load_regression_triggers, project, issue)).to be_empty
    end

    # @spec PAGE-LOAD-FOLLOWUP-005
    it "emits nothing while a performance follow-up run for the pull request is already active" do
      finding(actionable: true)
      create(:agent_run,
        project: project, issue: issue, source_pull_request_number: 42,
        focus: "performance_regression", status: "running")

      expect(activity.send(:page_load_regression_triggers, project, issue)).to be_empty
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "carries the finding's evidence on the trigger" do
      finding(route_name: "dashboard", actionable: true, baseline_ms: 640, current_ms: 1_100)

      trigger = activity.send(:page_load_regression_triggers, project, issue).first

      expect(trigger[:evidence]).to include(
        "route_name" => "dashboard",
        "comparison_metric" => "lcp_ms",
        "baseline_ms" => 640,
        "current_ms" => 1_100
      )
    end

    # @spec FOCUSED-RUN-002
    it "resolves the page_load_regression trigger to the performance_regression focus" do
      triggers = [ { type: "page_load_regression" } ]

      expect(activity.send(:resolve_focus, triggers)).to eq("performance_regression")
    end

    # @spec FOCUSED-RUN-002
    it "prioritizes correctness focuses over a performance regression" do
      triggers = [ { type: "page_load_regression" }, { type: "ci_failure" } ]

      expect(activity.send(:resolve_focus, triggers)).to eq("ci_fix")
    end
  end
end
