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

      expect(Scaling::QueueMonitor).to have_received(:call).with(no_args)
    end

    it "runs the agent_run_queue monitor per account with precomputed depth" do
      described_class.perform_now

      expect(Scaling::QueueMonitor).to have_received(:call).with(account: account, only: :agent_run_queue, precomputed_depth: 0)
    end

    it "precomputes waiting queued depth without counting claimed runs" do
      project = create(:project, account: account)
      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-123")

      described_class.perform_now

      expect(Scaling::QueueMonitor).to have_received(:call).with(account: account, only: :agent_run_queue, precomputed_depth: 1)
    end

    it "writes combined result to the dashboard cache for each account" do
      allow(Scaling::QueueMonitor).to receive(:write_cache).and_call_original

      described_class.perform_now

      expect(Scaling::QueueMonitor).to have_received(:write_cache).with(
        account,
        an_object_having_attributes(healthy?: true, queue_depths: be_an(Array))
      )
    end

    it "broadcasts queue health to each account dashboard" do
      described_class.perform_now

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "dashboard-queue-health")
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
        allow(Scaling::QueueMonitor).to receive(:call).with(account: account, only: :agent_run_queue, precomputed_depth: 0).and_return(alert_result)
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
