# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDashboardMetricsSweepJob do
  describe "#perform" do
    # @spec PROJECT-DASHBOARD-METRICS-002
    it "refreshes every active project and skips inactive projects" do
      active_project = create(:project, active: true)
      create(:project, active: false)
      allow(ProjectDashboardMetrics::Snapshot).to receive(:refresh)

      described_class.perform_now

      expect(ProjectDashboardMetrics::Snapshot).to have_received(:refresh).with(project: active_project)
        .once
    end
  end
end
