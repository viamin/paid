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

  def admission_for(host:, limit:)
    described_class.call(
      user: user,
      project: project,
      docker_snapshot: docker_snapshot,
      selected_host: host,
      selected_host_limit: limit
    )
  end

  describe ".call" do
    it "counts active runs against the selected host limit only" do
      create(:agent_run, :running, project: project, container_host: "local")
      3.times { create(:agent_run, :running, project: project, container_host: "elguapo") }

      local_result = admission_for(host: "local", limit: 2)
      elguapo_result = admission_for(host: "elguapo", limit: 4)
      aws_result = admission_for(host: "aws-runner-1", limit: 8)

      expect(local_result[:host_active_count]).to eq(1)
      expect(local_result[:host_available_slots]).to eq(1)
      expect(elguapo_result[:host_active_count]).to eq(3)
      expect(elguapo_result[:host_available_slots]).to eq(1)
      expect(aws_result[:host_active_count]).to eq(0)
      expect(aws_result[:host_available_slots]).to eq(8)
    end

    # @spec CONTAINER-RUNTIME-003
    it "counts claimed runs against their planned host before provisioning commits" do
      # Claimed run admitted for elguapo but not yet provisioned: container_host
      # is blank and the planned host is recorded in external_metadata, exactly
      # as ProcessRunQueueJob#start_claimed_run leaves it.
      create(:agent_run, :queued, project: project, container_host: nil,
                                  temporal_workflow_id: "claimed",
                                  external_metadata: { "planned_container_host" => "elguapo" })
      create(:agent_run, :running, project: project, container_host: "elguapo")

      elguapo_result = admission_for(host: "elguapo", limit: 4)
      local_result = admission_for(host: "local", limit: 2)

      # The claimed run charges elguapo (its planned host), not local, so a
      # remote host cannot be over-admitted during the claim window.
      expect(elguapo_result[:host_active_count]).to eq(2)
      expect(elguapo_result[:host_available_slots]).to eq(2)
      expect(local_result[:host_active_count]).to eq(0)
    end

    it "returns a host concurrency denial when the selected host is full" do
      4.times { create(:agent_run, :running, project: project, container_host: "elguapo") }

      result = described_class.call(
        user: user,
        project: project,
        docker_snapshot: docker_snapshot,
        selected_host: "elguapo",
        selected_host_limit: 4
      )

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("host_hard_ceiling")
      expect(result[:selected_host]).to eq("elguapo")
      expect(result[:host_active_count]).to eq(4)
      expect(result[:host_available_slots]).to eq(0)
    end

    it "still enforces user guardrails across all hosts" do
      user.settings.update!(run_concurrency_mode: "manual", max_concurrent_runs: 2)
      create(:agent_run, :running, project: project, container_host: "local")
      create(:agent_run, :running, project: project, container_host: "aws-runner-1")

      result = described_class.call(
        user: user,
        project: project,
        selected_host: "elguapo",
        selected_host_limit: 4
      )

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("user_hard_ceiling")
      expect(result[:host_active_count]).to eq(0)
    end

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

    # @spec CONTAINER-RUNTIME-006
    it "fails closed when Docker sampling times out even if slot ceilings still have room" do
      result = described_class.call(
        user: user,
        project: project,
        docker_snapshot: {
          available: false,
          reason: "container_sampling_budget_exceeded",
          snapshot_at: Time.current,
          confidence: "low",
          docker_memory_bytes: 20.gigabytes,
          agent_container_count: 4,
          agent_memory_bytes: 0
        }
      )

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("docker_sampling_budget_exceeded")
      expect(result[:available_slots]).to eq(0)
      expect(result[:reserved_agent_memory_bytes]).to eq(24.gigabytes)
      expect(result[:docker_agent_container_count]).to eq(4)
      expect(result[:docker_reason]).to eq("container_sampling_budget_exceeded")
      expect(result[:degraded]).to be true
    end

    it "supports forcing manual mode for one admission without changing user settings" do
      expect(Capacity::DockerSnapshot).not_to receive(:fetch)

      result = described_class.call(user: user, project: project, mode: "manual")

      expect(result[:mode]).to eq("manual")
      expect(result[:snapshot_available]).to be(false)
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

    describe "global concurrent execution limit" do
      before do
        allow(Capacity::GlobalLimit).to receive(:max_concurrent_executions).and_return(2)
      end

      it "denies admission when the global limit is reached" do
        2.times { create(:agent_run, :running, project: project) }

        result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("global_hard_ceiling")
        expect(result[:global_active_count]).to eq(2)
        expect(result[:global_max_concurrent_executions]).to eq(2)
        expect(result[:global_available_slots]).to eq(0)
      end

      it "counts inflight runs from other accounts against the global limit" do
        other_account = create(:account)
        other_user = create(:user, account: other_account)
        other_project = create(:project, account: other_account, created_by: other_user)
        create(:agent_run, :running, project: other_project)
        create(:agent_run, :running, project: project)

        result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("global_hard_ceiling")
        expect(result[:global_active_count]).to eq(2)
      end

      it "allows admission when the global limit has remaining slots" do
        create(:agent_run, :running, project: project)

        result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

        expect(result[:allowed]).to be true
        expect(result[:global_active_count]).to eq(1)
        expect(result[:global_available_slots]).to eq(1)
      end

      it "distinguishes global_hard_ceiling from user_hard_ceiling" do
        user.settings.update!(run_concurrency_mode: "manual", max_concurrent_runs: 1)
        create(:agent_run, :running, project: project)

        # Global limit is 2, user limit is 1 — user is the binding constraint
        result = described_class.call(user: user, project: project)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("user_hard_ceiling")
      end

      it "distinguishes global_hard_ceiling from host_hard_ceiling" do
        create(:agent_run, :running, project: project, container_host: "elguapo")
        create(:agent_run, :running, project: project, container_host: "aws-1")

        # Global limit is 2 (exhausted), host elguapo has limit 4 (1 used)
        result = described_class.call(
          user: user, project: project, docker_snapshot: docker_snapshot,
          selected_host: "elguapo", selected_host_limit: 4
        )

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("global_hard_ceiling")
      end
    end

    describe "global limit in manual mode" do
      before do
        user.settings.update!(run_concurrency_mode: "manual", max_concurrent_runs: 10)
        allow(Capacity::GlobalLimit).to receive(:max_concurrent_executions).and_return(2)
      end

      it "denies when global limit is reached even in manual mode" do
        2.times { create(:agent_run, :running, project: project) }

        result = described_class.call(user: user, project: project)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("global_hard_ceiling")
        expect(result[:mode]).to eq("manual")
      end
    end

    describe "global limit does not affect Docker auto mode when below ceiling" do
      it "allows admission in auto mode with a high global limit" do
        allow(Capacity::GlobalLimit).to receive(:max_concurrent_executions).and_return(50)

        result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

        expect(result[:allowed]).to be true
        expect(result[:mode]).to eq("auto")
        expect(result[:snapshot_available]).to be true
      end
    end

    describe "global limit disabled" do
      before do
        # 0 disables the global ceiling (consistent with GlobalLimit.enabled?
        # and the per-host "0 means unlimited" convention), so dispatch must
        # not be blocked even when inflight runs exist.
        allow(Capacity::GlobalLimit).to receive(:max_concurrent_executions).and_return(0)
      end

      it "does not block dispatch and reports nil available slots" do
        create(:agent_run, :running, project: project)

        result = described_class.call(user: user, project: project, docker_snapshot: docker_snapshot)

        expect(result[:allowed]).to be true
        expect(result[:reason]).to be_nil
        expect(result[:global_available_slots]).to be_nil
        expect(result[:global_max_concurrent_executions]).to eq(0)
      end

      it "does not raise in manual mode when the global ceiling is disabled" do
        user.settings.update!(run_concurrency_mode: "manual", max_concurrent_runs: 10)
        create(:agent_run, :running, project: project)

        result = described_class.call(user: user, project: project)

        expect(result[:allowed]).to be true
        expect(result[:mode]).to eq("manual")
        expect(result[:global_available_slots]).to be_nil
      end
    end
  end
end
