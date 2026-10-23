# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDashboardMetrics::Snapshot do
  let(:project) { create(:project) }

  describe ".refresh" do
    # @spec PROJECT-DASHBOARD-METRICS-002
    it "caches the project metrics for one day" do
      allow(Rails.cache).to receive(:write)
      create(:issue, :pull_request, project: project, pr_review_phase: "merged",
        github_created_at: 3.hours.ago, github_updated_at: 1.hour.ago)
      create(:external_connector_event, :processed, project: project,
        event_type: "pipeline_completed", normalized_data: { "duration_seconds" => 600 })
      create(:agent_run, :completed, project: project, tokens_input: 900, tokens_output: 100)

      snapshot = described_class.refresh(project: project)

      expect(snapshot).to eq(
        average_merge_seconds: 7200,
        average_ci_seconds: 600,
        average_tokens_per_pr: 1000,
        calculated_on: Time.zone.today
      )
      expect(Rails.cache).to have_received(:write).with(
        "project_dashboard_metrics/#{project.id}", snapshot, expires_in: 2.days
      )
    end

    # @spec PROJECT-DASHBOARD-METRICS-003
    it "leaves metrics without source observations unavailable" do
      snapshot = described_class.refresh(project: project)

      expect(snapshot).to include(
        average_merge_seconds: nil,
        average_ci_seconds: nil,
        average_tokens_per_pr: nil
      )
    end
  end
end
