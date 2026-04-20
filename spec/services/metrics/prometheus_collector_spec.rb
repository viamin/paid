# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::PrometheusCollector do
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

    it "includes service container metrics" do
      expect(output).to include("paid_service_containers_total")
    end

    it "includes temporal config metrics" do
      expect(output).to include("paid_temporal_workflow_slots_total")
      expect(output).to include("paid_temporal_activity_slots_total")
      expect(output).to include("paid_temporal_workflows_running")
      expect(output).to include("paid_temporal_workflow_utilization_percent")
    end

    context "with agent runs in various statuses" do
      before do
        create(:agent_run, :running, container_id: "ctr-1")
        create(:agent_run, :running, container_id: "ctr-2")
        create(:agent_run, :queued)
        create(:agent_run, :completed)
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
        expect(output).to include("paid_temporal_workflow_utilization_percent 10.0")
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

    it "follows Prometheus text exposition format with TYPE and HELP lines" do
      lines = output.lines
      help_lines = lines.select { |l| l.start_with?("# HELP") }
      type_lines = lines.select { |l| l.start_with?("# TYPE") }

      expect(help_lines).not_to be_empty
      expect(type_lines).not_to be_empty
      expect(type_lines.length).to eq(help_lines.length)
    end
  end
end
