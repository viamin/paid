# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::PrometheusCollector do # @spec OBSERVABILITY-002
  before do
    GoodJob::Job.delete_all
    Rails.cache.clear
  end

  describe ".call" do
    subject(:output) { described_class.call }

    it "returns a string ending with newline" do
      expect(output).to be_a(String)
      expect(output).to end_with("\n")
    end

    it "includes agent run metrics" do
      expect(output).to include("paid_agent_runs_total")
      expect(output).to include("paid_agent_runs_active")
      expect(output).to include("paid_agent_runs_queued")
      expect(output).to include("paid_agent_run_outcomes_window")
      expect(output).to include("paid_agent_run_duration_seconds_bucket_window")
      expect(output).to include("paid_agent_run_duration_seconds_sum_window")
      expect(output).to include("paid_agent_run_duration_seconds_count_window")
      expect(output).to include("paid_agent_run_tokens_window")
      expect(output).to include("paid_agent_run_cost_cents_window")
    end

    it "includes GoodJob metrics" do
      expect(output).to include("paid_goodjob_queue_depth")
      expect(output).to include("paid_goodjob_jobs_unfinished")
      expect(output).to include("paid_goodjob_jobs_running")
      expect(output).to include("paid_goodjob_jobs_errored")
    end

    it "includes container metrics" do
      expect(output).to include("paid_containers_active")
    end

    it "includes container pool metrics" do
      expect(output).to include("paid_container_pool_entries_total")
      expect(output).to include("paid_container_pool_target")
    end

    it "includes service container metrics" do
      expect(output).to include("paid_service_containers_total")
    end

    it "includes temporal config metrics" do
      expect(output).to include("paid_temporal_workflow_slots_total")
      expect(output).to include("paid_temporal_activity_slots_total")
      expect(output).to include("paid_temporal_workflows_running")
      expect(output).to include("paid_temporal_workflow_utilization_percent")
    end

    it "includes capacity metrics" do
      expect(output).to include("paid_capacity_global_concurrent_executions")
      expect(output).to include("paid_capacity_global_concurrent_limit")
      expect(output).to include("paid_capacity_host_concurrent_executions")
      expect(output).to include("paid_capacity_host_concurrent_limit")
    end

    context "with agent runs in various statuses" do
      before do
        create(:agent_run, :running, container_id: "ctr-1")
        create(:agent_run, :running, container_id: "ctr-2")
        create(:agent_run, :queued)
        create(:agent_run, :queued, temporal_workflow_id: "wf-123")
        create(:agent_run, :completed, :with_metrics, duration_seconds: 120)
        create(:agent_run, :failed, tokens_input: 30, tokens_output: 10, cost_cents: 7, duration_seconds: 300)
        create(:agent_run, :cancelled, tokens_input: 20, tokens_output: 0, cost_cents: 0, duration_seconds: 90)
      end

      it "reports correct active count" do
        expect(output).to include("paid_agent_runs_active 2")
      end

      it "reports correct queued count" do
        expect(output).to include("paid_agent_runs_queued 1")
      end

      it "reports running count in status breakdown" do
        expect(output).to include('paid_agent_runs_total{status="running"} 2')
      end

      it "reports active container count" do
        expect(output).to include("paid_containers_active 2")
      end

      it "reports terminal run outcomes as snapshot gauges" do
        expect(output).to include('paid_agent_run_outcomes_window{status="completed",outcome="success"} 1')
        expect(output).to include('paid_agent_run_outcomes_window{status="failed",outcome="failure"} 1')
        expect(output).to include('paid_agent_run_outcomes_window{status="cancelled",outcome="non_provider"} 1')
      end

      it "maps no_output to the success outcome bucket" do
        create(:agent_run, :no_output, tokens_input: 400, tokens_output: 0, cost_cents: 3,
               completed_at: Time.current, duration_seconds: 45)
        Rails.cache.clear
        refreshed = described_class.call

        expect(refreshed).to include('paid_agent_run_outcomes_window{status="no_output",outcome="success"} 1')
        expect(refreshed).to include('paid_agent_run_tokens_window{direction="input",outcome="success"} 10400')
      end

      it "reports duration distribution gauges and aggregates" do
        expect(output).to include('paid_agent_run_duration_seconds_bucket_window{outcome="success",le="300"} 1')
        expect(output).to include('paid_agent_run_duration_seconds_bucket_window{outcome="failure",le="300"} 1')
        expect(output).to include('paid_agent_run_duration_seconds_bucket_window{outcome="non_provider",le="300"} 1')
        expect(output).to include('paid_agent_run_duration_seconds_sum_window{outcome="success"} 120')
        expect(output).to include('paid_agent_run_duration_seconds_sum_window{outcome="failure"} 300')
        expect(output).to include('paid_agent_run_duration_seconds_sum_window{outcome="non_provider"} 90')
        expect(output).to include('paid_agent_run_duration_seconds_count_window{outcome="success"} 1')
        expect(output).to include('paid_agent_run_duration_seconds_count_window{outcome="failure"} 1')
        expect(output).to include('paid_agent_run_duration_seconds_count_window{outcome="non_provider"} 1')
      end

      it "reports token gauges split by direction and outcome" do
        expect(output).to include('paid_agent_run_tokens_window{direction="input",outcome="success"} 10000')
        expect(output).to include('paid_agent_run_tokens_window{direction="output",outcome="success"} 5000')
        expect(output).to include('paid_agent_run_tokens_window{direction="input",outcome="failure"} 30')
        expect(output).to include('paid_agent_run_tokens_window{direction="output",outcome="failure"} 10')
        expect(output).to include('paid_agent_run_tokens_window{direction="input",outcome="non_provider"} 20')
        expect(output).to include('paid_agent_run_tokens_window{direction="output",outcome="non_provider"} 0')
      end

      it "reports cost gauges by outcome" do
        expect(output).to include('paid_agent_run_cost_cents_window{outcome="success"} 150')
        expect(output).to include('paid_agent_run_cost_cents_window{outcome="failure"} 7')
        expect(output).to include('paid_agent_run_cost_cents_window{outcome="non_provider"} 0')
      end

      it "updates finished-run gauges when a terminal row mutates" do
        expect(output).to include('paid_agent_run_outcomes_window{status="failed",outcome="failure"} 1')
        AgentRun.find_by!(status: "failed").update!(status: "retried")
        Rails.cache.clear
        refreshed_output = described_class.call
        expect(refreshed_output).to include('paid_agent_run_outcomes_window{status="failed",outcome="failure"} 0')
        expect(refreshed_output).to include('paid_agent_run_outcomes_window{status="retried",outcome="non_provider"} 1')
      end

      it "excludes finished runs older than the FINISHED_RUN_WINDOW" do
        create(
          :agent_run,
          :completed,
          :with_metrics,
          duration_seconds: 45,
          completed_at: (Metrics::PrometheusCollector::FINISHED_RUN_WINDOW + 1.hour).ago
        )

        expect(output).not_to include('paid_agent_run_outcomes_window{status="completed",outcome="success"} 2')
        expect(output).to include('paid_agent_run_outcomes_window{status="completed",outcome="success"} 1')
      end
    end

    context "with container resource metrics" do
      let(:agent_run) { create(:agent_run, :running, container_id: "ctr-resource") }

      before do
        create(:container_metric,
          agent_run: agent_run,
          container_id: "ctr-resource",
          cpu_percent: 50.0,
          memory_bytes: 2_147_483_648,
          memory_limit_bytes: 4_294_967_296,
          memory_percent: 50.0,
          recorded_at: 1.minute.ago)
      end

      it "includes average CPU metrics" do
        expect(output).to include("paid_containers_avg_cpu_percent 50.0")
      end

      it "includes average memory metrics" do
        expect(output).to include("paid_containers_avg_memory_percent 50.0")
      end

      it "includes total memory bytes" do
        expect(output).to include("paid_containers_total_memory_bytes 2147483648")
      end
    end

    context "with service containers" do
      before do
        create(:service_container, :running)
        create(:service_container, status: "stopped")
      end

      it "reports counts by status" do
        running = ServiceContainer.where(status: "running").count
        stopped = ServiceContainer.where(status: "stopped").count

        expect(output).to include(%(paid_service_containers_total{status="running"} #{running}))
        expect(output).to include(%(paid_service_containers_total{status="stopped"} #{stopped}))
      end
    end

    context "with multi-host pool replenishment" do
      before do
        create(:project)
        allow(Containers).to receive(:all_backends).and_return([
          instance_double(Containers::Backends::Base, identifier: "local"),
          instance_double(Containers::Backends::Base, identifier: "worker-1")
        ])
      end

      it "reports the effective target across all active backends" do
        expect(output).to include(
          "paid_container_pool_target #{Containers::PoolManager.target_size * 2}"
        )
      end
    end

    context "with service container resource metrics" do
      before do
        sc = create(:service_container, :running)
        create(:service_container_metric,
          service_container: sc,
          cpu_percent: 30.0,
          memory_percent: 40.0,
          recorded_at: 1.minute.ago)
      end

      it "includes service container CPU metrics" do
        expect(output).to include("paid_service_containers_avg_cpu_percent 30.0")
      end

      it "includes service container memory metrics" do
        expect(output).to include("paid_service_containers_avg_memory_percent 40.0")
      end
    end

    context "with stopped service container metrics" do
      before do
        stopped = create(:service_container, status: "stopped")
        create(:service_container_metric,
          service_container: stopped,
          cpu_percent: 90.0,
          memory_percent: 80.0,
          recorded_at: 1.minute.ago)
      end

      it "excludes stopped containers from resource averages" do
        expect(output).not_to include("paid_service_containers_avg_cpu_percent")
      end
    end

    context "with temporal workflows" do
      before do
        create(:agent_run, :running, temporal_workflow_id: "wf-1")
        create(:agent_run, :running, temporal_workflow_id: "wf-2")
      end

      it "reports running temporal workflows" do
        expect(output).to include("paid_temporal_workflows_running 2")
      end

      it "reports workflow utilization" do
        workflow_slots = TenantSetting.resolve_worker_setting(
          "temporal_workflow_slots",
          env_key: "TEMPORAL_WORKFLOW_SLOTS",
          env: ENV,
          default: 20
        )
        expected_utilization = (2.0 / workflow_slots * 100).round(2)

        expect(output).to include("paid_temporal_workflow_utilization_percent #{expected_utilization}")
      end
    end

    context "with GoodJob jobs" do
      before do
        GoodJob::Job.create!(queue_name: "default", serialized_params: { "job_class" => "TestJob" })
        GoodJob::Job.create!(queue_name: "default", serialized_params: { "job_class" => "TestJob" })
        GoodJob::Job.create!(queue_name: "metrics", serialized_params: { "job_class" => "TestJob" })
      end

      it "reports queue depth per queue" do
        expect(output).to include('paid_goodjob_queue_depth{queue="default"} 2')
        expect(output).to include('paid_goodjob_queue_depth{queue="metrics"} 1')
      end

      it "reports total unfinished jobs" do
        expect(output).to include("paid_goodjob_jobs_unfinished 3")
      end
    end

    context "with capacity-inflight runs" do
      before do
        create(:agent_run, :running)
        create(:agent_run, :running)
        allow(Capacity::GlobalLimit).to receive(:max_concurrent_executions).and_return(10)
      end

      it "reports the global concurrent execution count" do
        expect(output).to include("paid_capacity_global_concurrent_executions 2")
      end

      it "reports the global concurrent execution limit" do
        expect(output).to include("paid_capacity_global_concurrent_limit 10")
      end
    end

    it "follows Prometheus text exposition format with TYPE and HELP lines" do
      lines = output.lines
      help_lines = lines.select { |l| l.start_with?("# HELP") }
      type_lines = lines.select { |l| l.start_with?("# TYPE") }

      expect(help_lines).not_to be_empty
      expect(type_lines).not_to be_empty
      expect(type_lines.length).to eq(help_lines.length)
    end

    it "declares mutable finished-run aggregates as gauges" do
      expect(output).to include("# TYPE paid_agent_run_outcomes_window gauge\n")
      expect(output).to include("# TYPE paid_agent_run_duration_seconds_bucket_window gauge\n")
      expect(output).to include("# TYPE paid_agent_run_duration_seconds_sum_window gauge\n")
      expect(output).to include("# TYPE paid_agent_run_duration_seconds_count_window gauge\n")
      expect(output).to include("# TYPE paid_agent_run_tokens_window gauge\n")
      expect(output).to include("# TYPE paid_agent_run_cost_cents_window gauge\n")
    end
  end
end
