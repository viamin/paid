# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveBroadcaster do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:agent_run) { create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago) }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
      allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
    end

    it "broadcasts live stats and active runs" do
      described_class.call(account: account, agent_run: agent_run)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "live-stats", partial: "dashboard/live_stats")
      )
      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "active-runs", partial: "dashboard/active_runs")
      )
    end

    it "broadcasts activity stream when a run finishes" do
      agent_run.update!(status: "completed", completed_at: Time.current, duration_seconds: 30)

      described_class.call(account: account, agent_run: agent_run)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "activity-stream", partial: "dashboard/activity_stream")
      )
    end

    it "broadcasts an alert for failures" do
      agent_run.update!(status: "failed", completed_at: Time.current, error_message: "Boom")

      described_class.call(account: account, agent_run: agent_run)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "dashboard-alerts", partial: "dashboard/alert")
      )
    end
  end
end
