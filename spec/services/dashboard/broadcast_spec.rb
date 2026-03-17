# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::Broadcast do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    context "when agent run transitions to a finished state" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      before do
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
        agent_run.update!(status: "failed", error_message: "An error occurred", completed_at: Time.current)
        # Reset message expectations after update! so after_commit broadcasts
        # don't count toward the assertions below.
        RSpec::Mocks.space.proxy_for(Turbo::StreamsChannel).reset
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
      end

      it "broadcasts live stats update" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to)
          .with([ account, :dashboard ], hash_including(target: "live-stats"))
          .once
      end

      it "broadcasts active runs update" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to)
          .with([ account, :dashboard ], hash_including(target: "active-runs"))
          .once
      end

      it "broadcasts activity stream for finished runs" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to)
          .with([ account, :dashboard ], hash_including(target: "activity-stream"))
          .once
      end

      it "broadcasts alert for failed runs" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to)
          .with([ account, :dashboard ], hash_including(target: "dashboard-alerts"))
          .once
      end
    end

    context "when agent run transitions to running" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      before do
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
      end

      it "does not broadcast an alert" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).not_to have_received(:broadcast_prepend_to)
      end
    end

    context "when agent run times out" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      before do
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
        agent_run.update!(status: "timeout", completed_at: Time.current)
        RSpec::Mocks.space.proxy_for(Turbo::StreamsChannel).reset
        allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
      end

      it "broadcasts a warning alert" do
        described_class.call(account: account, agent_run: agent_run)

        expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to)
          .with([ account, :dashboard ], hash_including(
            target: "dashboard-alerts",
            locals: hash_including(alert_type: "warning")
          ))
          .once
      end
    end
  end
end
