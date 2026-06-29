# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Operations::Dashboard do
  describe ".call" do
    let(:account) { create(:account) }
    let(:tenant_setting) { account.tenant_setting! }
    let(:project) { create(:project, account: account) }

    before do
      create(:billing_plan, :per_run, account: account)
      create(:billing_period, account: account, total_cost_cents: 15_000, total_runs: 12, starts_at: 20.days.ago, ends_at: 10.days.from_now)
      create(:user, :owner, account: account)
      allow(Accounts::Operations::AutoCapacityObserver).to receive(:call).and_return(
        {
          status: :healthy,
          sampled_at: Time.current,
          docker_cpu_count: 8,
          docker_memory_bytes: 8.gigabytes,
          running_agent_count: 1,
          estimated_next_run_memory_bytes: 2.gigabytes,
          available_agent_memory_bytes: 4.gigabytes,
          control_plane_margin_bytes: 512.megabytes,
          effective_recommended_concurrency: 2,
          usage: {
            paid: { container_count: 1, cpu_percent: 15.0, memory_bytes: 2.gigabytes },
            agent: { container_count: 1, cpu_percent: 40.0, memory_bytes: 1.gigabyte },
            service: { container_count: 0, cpu_percent: 0.0, memory_bytes: 0 },
            other: { container_count: 0, cpu_percent: 0.0, memory_bytes: 0 }
          },
          warnings: [],
          manual_mode_summary: "Manual mode is enforcing a fixed limit of 2 concurrent runs today.",
          auto_mode_summary: "Auto preview would allow 2 concurrent runs because Docker currently has 4 GB available for agents and recent runs suggest 2 GB per run.",
          comparison_summary: "Manual and auto would currently allow the same concurrency."
        }
      )
      allow(Scaling::QueueMonitor).to receive(:cached_for_account).and_return(
        Scaling::QueueMonitor::Result.new(
          queue_depths: [
            Scaling::QueueMonitor::QueueDepth.new(
              name: "agent_runs",
              type: :agent_run_queue,
              depth: 3,
              threshold_warning: 20,
              threshold_critical: 50,
              status: :ok
            )
          ],
          alerts: [],
          healthy?: true
        )
      )
    end

    it "builds a customer-visible operations summary" do
      create(:agent_run, project: project, created_at: 5.days.ago, started_at: 5.days.ago + 3.minutes, status: "completed")
      create(:agent_run, project: project, created_at: 4.days.ago, started_at: 4.days.ago + 8.minutes, status: "completed")
      create_resolved_p1_incident!
      configure_operations!

      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: true)

      expect(result.dig(:service_levels, :queue_health_actual_percent)).to eq(100.0)
      expect(result.dig(:service_levels, :uptime_actual_percent)).to be < 100.0
      expect(result.dig(:disaster_recovery, :restore_drill_status)).to eq(:current)
      expect(result.dig(:capacity, :current_queue_depth)).to eq(3)
      expect(result.dig(:capacity, :current_period_cost_cents)).to eq(15_000)
    end

    it "hides billing-derived cost data when billing visibility is disabled" do
      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: false)

      expect(result.dig(:capacity, :current_period_cost_cents)).to be_nil
      expect(result.dig(:capacity, :cost_ceiling_utilization_percent)).to be_nil
    end

    it "reuses calculated service level metrics within a payload build" do
      configure_operations!
      dashboard = described_class.new(account: account, tenant_setting: tenant_setting, billing_visible: true)

      expect(dashboard).to receive(:uptime_actual_percent).once.and_call_original
      expect(dashboard).to receive(:queue_health_actual_percent).once.and_call_original

      dashboard.send(:service_levels_payload)
    end

    def configure_operations!
      tenant_setting.enterprise_operations_configuration = {
        "service_levels" => { "queue_start_slo_minutes" => 10 },
        "disaster_recovery" => { "last_restore_drill_at" => 20.days.ago.to_date.iso8601 }
      }
      tenant_setting.save!
    end

    def create_resolved_p1_incident!
      create(
        :exception_incident,
        account: account,
        severity: "p1",
        status: "resolved",
        created_at: 2.days.ago,
        resolved_at: 2.days.ago + 30.minutes,
        last_occurred_at: 2.days.ago + 30.minutes
      )
    end
  end
end
