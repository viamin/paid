# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::RunAdmission do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:docker_snapshot) do
    {
      available: true,
      effective_agent_budget_bytes: 20.gigabytes,
      snapshot_at: Time.current,
      confidence: "high",
      docker_memory_bytes: 32.gigabytes
    }
  end

  before do
    user.settings.update!(
      run_concurrency_mode: "auto",
      max_concurrent_runs: nil,
      container_memory_bytes: 6.gigabytes
    )
  end

  describe ".call" do
    it "does not report a denial reason when optional project and goal caps do not apply" do
      result = described_class.call(user: user, docker_snapshot: docker_snapshot)

      expect(result[:allowed]).to be true
      expect(result[:reason]).to be_nil
    end

    it "uses the latest metric per inflight local run when summing reserved memory" do
      first_run = create(:agent_run, :running, project: project, container_host: Containers::LOCAL_BACKEND_KEY.to_s)
      second_run = create(:agent_run, :running, project: project, container_host: Containers::LOCAL_BACKEND_KEY.to_s)

      create(:container_metric, agent_run: first_run, memory_limit_bytes: 2.gigabytes, recorded_at: 2.minutes.ago)
      create(:container_metric, agent_run: first_run, memory_limit_bytes: 7.gigabytes, recorded_at: 1.minute.ago)
      create(:container_metric, agent_run: second_run, memory_limit_bytes: 1.gigabyte, recorded_at: 2.minutes.ago)
      create(:container_metric, agent_run: second_run, memory_limit_bytes: 5.gigabytes, recorded_at: 1.minute.ago)

      result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

      expect(result[:reserved_agent_memory_bytes]).to eq(12.gigabytes)
      expect(result[:available_memory_bytes]).to eq(8.gigabytes)
      expect(result[:available_slots]).to eq(1)
    end

    it "loads latest container metrics in one batched query" do
      3.times do |i|
        run = create(:agent_run, :running, project: project, container_host: Containers::LOCAL_BACKEND_KEY.to_s)
        create(:container_metric, agent_run: run, memory_limit_bytes: (i + 4).gigabytes, recorded_at: 1.minute.ago)
      end

      queries = capture_queries do
        described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)
      end

      metric_queries = queries.grep(/FROM "container_metrics"/)

      expect(metric_queries.size).to eq(1)
    end

    it "uses provided reserved agent memory bytes without rescanning inflight runs" do
      create(:agent_run, :running, project: project, container_host: Containers::LOCAL_BACKEND_KEY.to_s)

      queries = capture_queries do
        described_class.call(
          user: user,
          project: project,
          docker_snapshot: docker_snapshot,
          reserved_agent_memory_bytes: 8.gigabytes
        )
      end

      expect(queries.grep(/FROM "container_metrics"/)).to be_empty
    end
  end
end
