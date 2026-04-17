# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueueMonitorJob do
  describe "#perform" do
    let!(:account) { create(:account) }

    let(:depth) do
      Scaling::QueueMonitor::QueueDepth.new(
        name: "default",
        type: :good_job,
        depth: 5,
        threshold_warning: 50,
        threshold_critical: 200,
        status: :ok
      )
    end

    let(:healthy_result) do
      Scaling::QueueMonitor::Result.new(
        queue_depths: [ depth ],
        alerts: [],
        healthy?: true
      )
    end

    before do
      allow(Scaling::QueueMonitor).to receive(:call).and_return(healthy_result)
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
    end

    it "runs the queue monitor globally" do
      described_class.perform_now

      expect(Scaling::QueueMonitor).to have_received(:call).with(no_args).at_least(:once)
    end

    it "runs the queue monitor per account" do
      described_class.perform_now

      expect(Scaling::QueueMonitor).to have_received(:call).with(account: account)
    end

    it "broadcasts queue health to each account dashboard" do
      described_class.perform_now

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "queue-health")
      )
    end

    context "when alerts exist" do
      let(:alert_result) do
        Scaling::QueueMonitor::Result.new(
          queue_depths: [ depth ],
          alerts: [
            Scaling::QueueMonitor::Alert.new(
              queue_name: "default",
              queue_type: :good_job,
              depth: 60,
              threshold: 50,
              severity: :warning
            )
          ],
          healthy?: true
        )
      end

      before do
        allow(Scaling::QueueMonitor).to receive(:call).with(account: account).and_return(alert_result)
      end

      it "publishes alerts for the account" do
        allow(Scaling::QueueAlert).to receive(:call)

        described_class.perform_now

        expect(Scaling::QueueAlert).to have_received(:call).with(
          account: account,
          alerts: alert_result.alerts
        )
      end
    end

    it "is enqueued on the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
