# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::Broadcast do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    context "when agent run transitions to a finished state" do
      let(:agent_run) { create(:agent_run, :failed, project: project) }

      it "broadcasts live stats update" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
          .with([ account, :dashboard ], hash_including(target: "live-stats"))
          .at_least(:once)
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)

        described_class.call(account: account, agent_run: agent_run)
      end

      it "broadcasts active runs update" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
          .with([ account, :dashboard ], hash_including(target: "active-runs"))
          .at_least(:once)
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)

        described_class.call(account: account, agent_run: agent_run)
      end

      it "broadcasts activity stream for finished runs" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
          .with([ account, :dashboard ], hash_including(target: "activity-stream"))
          .at_least(:once)
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)

        described_class.call(account: account, agent_run: agent_run)
      end

      it "broadcasts alert for failed runs" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
          .with([ account, :dashboard ], hash_including(target: "dashboard-alerts"))
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

        described_class.call(account: account, agent_run: agent_run)
      end
    end

    context "when agent run transitions to running" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      it "does not broadcast an alert" do
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        expect(Turbo::StreamsChannel).not_to receive(:broadcast_prepend_to)

        described_class.call(account: account, agent_run: agent_run)
      end
    end

    context "when agent run times out" do
      let(:agent_run) { create(:agent_run, :timeout, project: project) }

      it "broadcasts a warning alert" do
        expect(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
          .with([ account, :dashboard ], hash_including(
            target: "dashboard-alerts",
            locals: hash_including(alert_type: "warning")
          ))
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)

        described_class.call(account: account, agent_run: agent_run)
      end
    end
  end
end
