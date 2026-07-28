# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveDashboardBroadcastJob do
  describe "#perform" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "refreshes the queue preview when the run has re-entered the queue before perform time" do
      agent_run = create(:agent_run, :failed, project: project)
      agent_run.update!(status: "queued")

      allow(Dashboard::LiveBroadcaster).to receive(:call)

      described_class.perform_now(account.id, agent_run.id, refresh_queue_preview: false)

      expect(Dashboard::LiveBroadcaster).to have_received(:call).with(
        account: account,
        agent_run: have_attributes(id: agent_run.id, status: "queued"),
        refresh_queue_preview: true
      )
    end

    it "preserves an explicit queue refresh when the run has already left the queue" do
      agent_run = create(:agent_run, :queued, project: project)
      agent_run.update!(status: "failed")

      allow(Dashboard::LiveBroadcaster).to receive(:call)

      described_class.perform_now(account.id, agent_run.id, refresh_queue_preview: true)

      expect(Dashboard::LiveBroadcaster).to have_received(:call).with(
        account: account,
        agent_run: have_attributes(id: agent_run.id, status: "failed"),
        refresh_queue_preview: true
      )
    end
  end
end
