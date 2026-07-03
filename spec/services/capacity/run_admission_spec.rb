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
    it "uses account tenant caps when the user has no explicit manual limit" do
      user.settings.update!(run_concurrency_mode: "manual", max_concurrent_runs: 2)
      allow(user.settings).to receive(:max_concurrent_runs).and_return(nil)
      allow(account).to receive(:tenant_max_concurrent_runs).with(nil).and_return(7)

      result = described_class.call(user: user, project: project)

      expect(result[:effective_max_concurrent_runs]).to eq(7)
    end

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

    it "only reserves local agent headroom that is not already reflected in the Docker snapshot" do
      result = described_class.call(
        user: user,
        project: project,
        docker_snapshot: docker_snapshot.merge(agent_memory_bytes: 6.gigabytes, effective_agent_budget_bytes: 10.gigabytes),
        reserved_agent_memory_bytes: 8.gigabytes
      )

      expect(result[:reserved_agent_memory_bytes]).to eq(8.gigabytes)
      expect(result[:available_memory_bytes]).to eq(8.gigabytes)
      expect(result[:available_slots]).to eq(1)
    end

    it "preserves the manual denial reason when Docker inspection is unavailable" do
      user.settings.update!(max_parallel_agents_per_project: 1)
      create(:agent_run, :running, project: project)

      result = described_class.call(
        user: user,
        project: project,
        docker_snapshot: {
          available: false,
          reason: "docker_timeout",
          snapshot_at: Time.current,
          confidence: "low"
        }
      )

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("project_hard_ceiling")
      expect(result[:docker_reason]).to eq("docker_timeout")
      expect(result[:degraded]).to be true
    end

    it "annotates capacity_blocked when the matched profile has hit its ceiling" do
      profile = create(:agent_run_resource_profile,
        :project_level,
        account: account,
        project: project,
        runner_key: nil,
        goal: nil,
        sample_count: 8,
        oom_count: 3,
        recommended_memory_limit_bytes: 16.gigabytes)
      profile.update_columns(capacity_blocked: true, capacity_blocked_at: 1.minute.ago)

      # The annotation only fires when Docker memory is the binding
      # constraint, so drive the admission into an insufficient-capacity
      # denial before the lookup runs.
      constrained_snapshot = docker_snapshot.merge(effective_agent_budget_bytes: 4.gigabytes)

      result = described_class.call(user: user, project: project, docker_snapshot: constrained_snapshot)

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("insufficient_docker_capacity")
      expect(result[:capacity_blocked]).to be true
      expect(result[:capacity_blocked_profile_level]).to eq("project")
      expect(result[:capacity_blocked_recommended_limit_bytes]).to eq(16.gigabytes)
    end

    it "does not annotate capacity_blocked when the matched profile is not blocked" do
      create(:agent_run_resource_profile,
        :project_level,
        account: account,
        project: project,
        runner_key: nil,
        goal: nil,
        sample_count: 5,
        oom_count: 0,
        recommended_memory_limit_bytes: 4.gigabytes)

      constrained_snapshot = docker_snapshot.merge(effective_agent_budget_bytes: 4.gigabytes)

      result = described_class.call(user: user, project: project, docker_snapshot: constrained_snapshot)

      expect(result[:reason]).to eq("insufficient_docker_capacity")
      expect(result[:capacity_blocked]).to be_nil
    end

    it "skips the capacity-blocked lookup entirely when Docker memory is available" do
      # Allowed admissions must not pay for the Resolve lookup on the hot
      # path; capacity-blocked is only meaningful when memory-constrained.
      expect(AgentRunResourceProfiles::Resolve).not_to receive(:call)

      result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

      expect(result[:allowed]).to be true
      expect(result[:reason]).to be_nil
      expect(result[:capacity_blocked]).to be_nil
    end
  end
end

    it "does not annotate capacity_blocked when the matched profile is not blocked" do
      create(:agent_run_resource_profile,
        :project_level,
        account: account,
        project: project,
        runner_key: nil,
        goal: nil,
        sample_count: 5,
        oom_count: 0,
        recommended_memory_limit_bytes: 4.gigabytes
      )

      result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

      expect(result[:capacity_blocked]).to be_nil
    end
  end
end
