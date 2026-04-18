# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::QueueAlert do
  describe ".call" do
    let(:account) { create(:account) }

    let(:warning_alert) do
      Scaling::QueueMonitor::Alert.new(
        queue_name: "default",
        queue_type: :good_job,
        depth: 60,
        threshold: 50,
        severity: :warning
      )
    end

    let(:critical_alert) do
      Scaling::QueueMonitor::Alert.new(
        queue_name: "agent_runs",
        queue_type: :agent_run_queue,
        depth: 250,
        threshold: 200,
        severity: :critical
      )
    end

    it "publishes a warning notification for warning alerts" do
      described_class.call(account: account, alerts: [ warning_alert ])

      notification = Notification.find_by(account: account, source: "queue_monitor")
      expect(notification).to be_present
      expect(notification.severity).to eq("warning")
      expect(notification.title).to include("default")
    end

    it "publishes an error notification for critical alerts" do
      described_class.call(account: account, alerts: [ critical_alert ])

      notification = Notification.find_by(account: account, source: "queue_monitor")
      expect(notification).to be_present
      expect(notification.severity).to eq("error")
      expect(notification.title).to include("agent_runs")
    end

    it "stores queue metadata on the notification" do
      described_class.call(account: account, alerts: [ warning_alert ])

      notification = Notification.find_by(account: account, source: "queue_monitor")
      expect(notification.metadata).to include(
        "queue_name" => "default",
        "queue_type" => "good_job",
        "depth" => 60,
        "threshold" => 50
      )
    end

    it "resolves notifications for queues that have cleared" do
      # First create a notification
      described_class.call(account: account, alerts: [ warning_alert ])
      expect(Notification.where(account: account, source: "queue_monitor").active.count).to eq(1)

      # Now call with no alerts — the notification should be resolved
      described_class.call(account: account, alerts: [])
      expect(Notification.where(account: account, source: "queue_monitor").active.count).to eq(0)
    end
  end
end
