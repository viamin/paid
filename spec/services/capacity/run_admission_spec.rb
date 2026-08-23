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
  let(:infra_limits) do
    {
      global_requested_cpu_quota_limit: 2_000_000,
      host_requested_cpu_quota_limit: 1_000_000,
      global_requested_memory_bytes_limit: 64.gigabytes,
      host_requested_memory_bytes_limit: 32.gigabytes,
      global_requested_disk_bytes_limit: 24.gigabytes,
      host_requested_disk_bytes_limit: 12.gigabytes,
      max_execution_cpu_quota_limit: 400_000,
      max_execution_memory_bytes_limit: 16.gigabytes,
      max_execution_disk_bytes_limit: 4.gigabytes,
      provisioning_rate_window_seconds: 600,
      global_provisionings_per_window_limit: 10,
      account_provisionings_per_window_limit: 5,
      project_provisionings_per_window_limit: 3
    }
  end

  before do
    user.settings.update!(
      run_concurrency_mode: "auto",
      max_concurrent_runs: nil,
      container_memory_bytes: 6.gigabytes
    )
    allow(Capacity::InfrastructureLimits).to receive(:current).and_return(infra_limits)
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

  def requested_resource_metadata(cpu_quota:, memory_bytes:, disk_bytes:)
    {
      "requested_resources" => {
        "cpu_quota" => cpu_quota,
        "memory_bytes" => memory_bytes,
        "disk_bytes" => disk_bytes
      }
    }
  end

  def create_requested_run!(host: nil, provisioning_started_at: nil, cpu_quota: 200_000, memory_bytes: 2.gigabytes, disk_bytes: 1.gigabyte)
    create(
      :agent_run,
      :running,
      project: project,
      container_host: host,
      provisioning_started_at: provisioning_started_at,
      external_metadata: requested_resource_metadata(
        cpu_quota: cpu_quota,
        memory_bytes: memory_bytes,
        disk_bytes: disk_bytes
      ).tap do |metadata|
        metadata["provisioning_started_at"] = provisioning_started_at if provisioning_started_at
      end
    )
  end

  def create_requested_run_for!(target_project, host: nil, provisioning_started_at: nil, cpu_quota: 200_000, memory_bytes: 2.gigabytes, disk_bytes: 1.gigabyte)
    create(
      :agent_run,
      :running,
      project: target_project,
      container_host: host,
      provisioning_started_at: provisioning_started_at,
      external_metadata: requested_resource_metadata(
        cpu_quota: cpu_quota,
        memory_bytes: memory_bytes,
        disk_bytes: disk_bytes
      ).tap do |metadata|
        metadata["provisioning_started_at"] = provisioning_started_at if provisioning_started_at
      end
    )
  end

  # Records TenantContext.bypass_enabled? at the moment each host-aggregate
  # agent_runs query executes, so specs can assert the load happened inside
  # the RLS bypass even though the privileged spec connection cannot rely on
  # row-level security itself to filter rows.
  def host_aggregate_bypass_observer(states)
    lambda do |*, payload|
      sql = payload[:sql]
      return unless sql.include?('FROM "agent_runs"') && sql.include?("COALESCE(NULLIF(container_host")

      states << TenantContext.bypass_enabled?
    end
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

    # @spec CONTAINER-RUNTIME-025
    it "denies when the projected global requested memory would exceed the aggregate ceiling" do
      allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
        infra_limits.merge(global_requested_memory_bytes_limit: 16.gigabytes)
      )

      2.times { create_requested_run!(memory_bytes: 6.gigabytes) }

      result = admission_for(host: "local", limit: 8)

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("global_requested_memory_ceiling")
      expect(result[:current_global_requested_memory_bytes]).to eq(12.gigabytes)
      expect(result[:global_requested_memory_bytes_limit]).to eq(16.gigabytes)
    end

    # @spec CONTAINER-RUNTIME-025
    it "denies when the projected selected-host requested cpu would exceed the backend ceiling" do
      allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
        infra_limits.merge(host_requested_cpu_quota_limit: 500_000)
      )

      2.times { create_requested_run!(host: "elguapo") }

      result = admission_for(host: "elguapo", limit: 8)

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("host_requested_cpu_ceiling")
      expect(result[:current_host_requested_cpu_quota]).to eq(400_000)
      expect(result[:host_requested_cpu_quota_limit]).to eq(500_000)
    end

    # @spec CONTAINER-RUNTIME-025
    # Admission runs tenant-scoped in production (e.g. CheckRunCapacityActivity
    # under TenantContext.with(account)), while agent_runs has FORCE ROW LEVEL
    # SECURITY. The host aggregate must therefore be loaded while system access
    # is active — a relation that only escapes the bypass block before being
    # loaded would run RLS-scoped to the calling tenant and undercount the
    # shared host. The spec connection is privileged, so RLS itself cannot
    # filter rows here; observe the bypass state at query time instead.
    # reserved_agent_memory_bytes is passed so the reserved-memory rescan
    # (its own host-scoped agent_runs load) adds no unrelated samples.
    it "loads the host aggregate with system access even when admission runs tenant-scoped", :tenant_isolation do
      other_account = create(:account)
      other_project = create(:project, account: other_account, created_by: create(:user, account: other_account))
      TenantContext.with_system_access do
        create(:agent_run, :running, project: other_project, container_host: "elguapo",
          external_metadata: requested_resource_metadata(cpu_quota: 200_000, memory_bytes: 2.gigabytes, disk_bytes: 1.gigabyte))
      end

      bypass_states = []
      result = ActiveSupport::Notifications.subscribed(host_aggregate_bypass_observer(bypass_states), "sql.active_record") do
        TenantContext.with(account) do
          described_class.call(user: user, project: project, docker_snapshot: docker_snapshot,
            selected_host: "elguapo", selected_host_limit: 8, reserved_agent_memory_bytes: 12.gigabytes)
        end
      end

      expect(result[:current_host_requested_cpu_quota]).to eq(200_000)
      expect(bypass_states).to all(be(true))
    end

    # @spec CONTAINER-RUNTIME-026
    it "returns a provisioning-rate denial with the next eligible timestamp" do
      travel_to(Time.zone.parse("2026-08-17 12:00:00 UTC")) do
        create_requested_run!(provisioning_started_at: 5.minutes.ago.iso8601)

        allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
          infra_limits.merge(global_provisionings_per_window_limit: 1)
        )

        result = admission_for(host: "local", limit: 8)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("global_provisioning_rate_limit")
        expect(result[:rate_limited_until]).to eq(Time.zone.parse("2026-08-17 12:05:00 UTC"))
        expect(result[:current_global_provisionings_per_window]).to eq(1)
        expect(result[:global_provisionings_per_window_limit]).to eq(1)
      end
    end

    # @spec CONTAINER-RUNTIME-026
    it "filters stale provisioning starts in SQL before loading the window" do
      travel_to(Time.zone.parse("2026-08-17 12:00:00 UTC")) do
        create_requested_run!(provisioning_started_at: 11.minutes.ago.iso8601)
        create_requested_run!(provisioning_started_at: 5.minutes.ago.iso8601)

        statements = []
        subscriber = lambda do |*, payload|
          sql = payload[:sql]
          next unless sql.include?('"agent_runs"."provisioning_started_at"')

          statements << sql
        end

        result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          admission_for(host: "local", limit: 8)
        end

        expect(result[:current_global_provisionings_per_window]).to eq(1)
        expect(statements).to include(a_string_including('"agent_runs"."provisioning_started_at"'))
      end
    end

    # @spec CONTAINER-RUNTIME-026
    it "uses the matching account window when returning an account provisioning-rate denial" do
      travel_to(Time.zone.parse("2026-08-17 12:00:00 UTC")) do
        other_account = create(:account)
        other_user = create(:user, account: other_account)
        other_project = create(:project, account: other_account, created_by: other_user)

        create_requested_run_for!(other_project, provisioning_started_at: 9.minutes.ago.iso8601)
        create_requested_run!(provisioning_started_at: 4.minutes.ago.iso8601)

        allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
          infra_limits.merge(
            global_provisionings_per_window_limit: 10,
            account_provisionings_per_window_limit: 1
          )
        )

        result = admission_for(host: "local", limit: 8)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("account_provisioning_rate_limit")
        expect(result[:rate_limited_until]).to eq(Time.zone.parse("2026-08-17 12:06:00 UTC"))
      end
    end

    # @spec CONTAINER-RUNTIME-026
    it "uses the matching project window when returning a project provisioning-rate denial" do
      travel_to(Time.zone.parse("2026-08-17 12:00:00 UTC")) do
        sibling_project = create(:project, account: account, created_by: user)

        create_requested_run_for!(sibling_project, provisioning_started_at: 9.minutes.ago.iso8601)
        create_requested_run!(provisioning_started_at: 3.minutes.ago.iso8601)

        allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
          infra_limits.merge(
            global_provisionings_per_window_limit: 10,
            account_provisionings_per_window_limit: 10,
            project_provisionings_per_window_limit: 1
          )
        )

        result = admission_for(host: "local", limit: 8)

        expect(result[:allowed]).to be false
        expect(result[:reason]).to eq("project_provisioning_rate_limit")
        expect(result[:rate_limited_until]).to eq(Time.zone.parse("2026-08-17 12:07:00 UTC"))
      end
    end

    # @spec CONTAINER-RUNTIME-027
    it "denies when the requested execution disk exceeds the configured maximum" do
      allow(Capacity::InfrastructureLimits).to receive(:current).and_return(
        infra_limits.merge(max_execution_disk_bytes_limit: 1.gigabyte)
      )

      result = described_class.call(
        user: user,
        project: project,
        docker_snapshot: docker_snapshot,
        selected_host: "local",
        selected_host_limit: 8
      )

      expect(result[:allowed]).to be false
      expect(result[:reason]).to eq("execution_disk_limit_exceeded")
      expect(result[:requested_disk_bytes]).to be > 1.gigabyte
      expect(result[:max_execution_disk_bytes_limit]).to eq(1.gigabyte)
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

    # @spec INFRA-SPEND-001
    it "denies admission when projected infrastructure spend breaches a threshold" do
      allow(Capacity::InfrastructureSpendGuard).to receive(:call).and_return(
        allowed: false,
        reason: "project_infra_spend_hourly_limit_exceeded",
        rate_limited_until: Time.zone.parse("2026-08-17 13:00:00 UTC"),
        spend_scope: "project",
        spend_period: "hourly",
        spend_action: "park",
        current_spend_cents: 90,
        projected_spend_cents: 120,
        infra_spend_limit_cents: 100
      )

      result = admission_for(host: "local", limit: 8)

      expect(result[:allowed]).to be(false)
      expect(result[:reason]).to eq("project_infra_spend_hourly_limit_exceeded")
      expect(result[:available_slots]).to eq(0)
      expect(result[:rate_limited_until]).to eq(Time.zone.parse("2026-08-17 13:00:00 UTC"))
      expect(result[:spend_scope]).to eq("project")
      expect(result[:projected_spend_cents]).to eq(120)
      expect(result[:infra_spend_limit_cents]).to eq(100)
    end
  end
end
