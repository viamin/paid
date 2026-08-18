# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessRunQueueJob do
  let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:workflow_handle) { double("WorkflowHandle", id: "queued-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles
  let(:job) { described_class.new }
  let(:auto_mode_snapshot) do
    {
      available: true,
      effective_agent_budget_bytes: 2 * 1024 * 1024 * 1024,
      snapshot_at: Time.current,
      confidence: "high",
      docker_memory_bytes: 8 * 1024 * 1024 * 1024
    }
  end

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, agent_task_queue: "paid-agent-tasks")
    allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)
  end

  def temporal_priority_for(run)
    job.send(:temporal_priority_for, run)
  end

  def create_strict_priority_vs_fair_share_runs
    strict_account = create(:account)
    strict_account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")
    strict_user = create(:user, account: strict_account)
    strict_user.settings.update!(max_concurrent_runs: 1)
    busy_project = create(:project, account: strict_account, created_by: strict_user)

    fair_account = create(:account)
    fair_account.tenant_setting!.update!(queue_fairness_mode: "fair_share")
    fair_user = create(:user, account: fair_account)
    fair_user.settings.update!(max_concurrent_runs: 1)
    idle_project = create(:project, account: fair_account, created_by: fair_user)

    strict_issue_a = create(:issue, project: busy_project, labels: [ "P1" ])
    strict_issue_b = create(:issue, project: busy_project, labels: [ "P1" ])
    strict_issue_c = create(:issue, project: busy_project, labels: [ "P1" ])
    create(:agent_run, :running, project: busy_project, trigger_type: "automatic", issue: strict_issue_a)
    create(:agent_run, :running, project: busy_project, trigger_type: "automatic", issue: strict_issue_b)
    strict_run = create(:agent_run, :queued, project: busy_project, trigger_type: "automatic",
      issue: strict_issue_c, created_at: 2.minutes.ago)

    fair_issue = create(:issue, project: idle_project, labels: [ "P2" ])
    fair_run = create(:agent_run, :queued, project: idle_project, trigger_type: "automatic",
      issue: fair_issue, created_at: 1.minute.ago)

    [ strict_run, fair_run ]
  end

  def create_strict_priority_vs_strict_priority_runs
    first_account = create(:account)
    first_account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")
    first_user = create(:user, account: first_account)
    first_user.settings.update!(max_concurrent_runs: 1)
    busy_project = create(:project, account: first_account, created_by: first_user)

    second_account = create(:account)
    second_account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")
    second_user = create(:user, account: second_account)
    second_user.settings.update!(max_concurrent_runs: 1)
    idle_project = create(:project, account: second_account, created_by: second_user)

    first_issue_a = create(:issue, project: busy_project, labels: [ "P1" ])
    first_issue_b = create(:issue, project: busy_project, labels: [ "P1" ])
    first_issue_c = create(:issue, project: busy_project, labels: [ "P1" ])
    create(:agent_run, :running, project: busy_project, trigger_type: "automatic", issue: first_issue_a)
    create(:agent_run, :running, project: busy_project, trigger_type: "automatic", issue: first_issue_b)
    first_run = create(:agent_run, :queued, project: busy_project, trigger_type: "automatic",
      issue: first_issue_c, created_at: 2.minutes.ago)

    second_issue = create(:issue, project: idle_project, labels: [ "P2" ])
    second_run = create(:agent_run, :queued, project: idle_project, trigger_type: "automatic",
      issue: second_issue, created_at: 1.minute.ago)

    [ first_run, second_run ]
  end

  def build_host_registry(fallback_policy: "first_healthy")
    local_backend = instance_double(Containers::Backends::LocalDocker, identifier: "local", all_host_identifiers: [ "local" ], remote?: false, ping: true)
    elguapo_backend = instance_double(Containers::Backends::RemoteDocker, identifier: "elguapo", all_host_identifiers: [ "elguapo" ], remote?: true, ping: true)
    aws_backend = instance_double(Containers::Backends::RemoteDocker, identifier: "aws-runner-1", all_host_identifiers: [ "aws-runner-1" ], remote?: true, ping: true)
    registry = Containers::HostRegistry::Registry.new(
      default_host: "local",
      fallback_policy: fallback_policy,
      hosts: [
        Containers::HostRegistry::HostDefinition.new(identifier: "local", backend: local_backend, max_concurrent_runs: 2, fallback_enabled: true),
        Containers::HostRegistry::HostDefinition.new(identifier: "elguapo", backend: elguapo_backend, max_concurrent_runs: 4, fallback_enabled: true),
        Containers::HostRegistry::HostDefinition.new(identifier: "aws-runner-1", backend: aws_backend, max_concurrent_runs: 8, fallback_enabled: true)
      ]
    )

    { registry: registry, local_backend: local_backend, elguapo_backend: elguapo_backend, aws_backend: aws_backend }
  end

  def stub_multi_host_registry(registry_bundle)
    allow(Containers).to receive_messages(
      host_registry: registry_bundle.fetch(:registry),
      backend: registry_bundle.fetch(:local_backend)
    )
    allow(Containers).to receive(:backend_for).with("local").and_return(registry_bundle.fetch(:local_backend))
    allow(Containers).to receive(:backend_for).with("elguapo").and_return(registry_bundle.fetch(:elguapo_backend))
    allow(Containers).to receive(:backend_for).with("aws-runner-1").and_return(registry_bundle.fetch(:aws_backend))
    allow(Containers::Provision).to receive(:compatibility_for)
      .and_return(Containers::Provision::CompatibilityResult.new(compatible: true, error_message: nil))
  end

  def create_host_saturation_runs(host_counts)
    other_account = create(:account)
    other_user = create(:user, account: other_account)

    host_counts.each do |host, count|
      count.times do
        create(:agent_run, :running, project: create(:project, account: other_account, created_by: other_user), container_host: host)
      end
    end
  end

  def create_host_selected_run(project:, host:, created_at:)
    create(:agent_run, :queued, project: project, created_at: created_at, external_metadata: {
      "container_host_selection" => {
        "explicit_host" => host
      }
    })
  end

  def create_preferred_host_run(project:, host: "elguapo", fallback: "first_healthy")
    create(:agent_run, :queued, project: project, external_metadata: {
      "container_host_selection" => {
        "preferred_host" => host,
        "fallback" => fallback
      }
    })
  end

  def expect_host_selected_log(run_id:, requested_host:, selected_host:, selection_source:, selection_reason:, fallback_policy:, fallback_chain:)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "process_run_queue.host_selected",
        agent_run_id: run_id,
        requested_host: requested_host,
        selected_host: selected_host,
        selection_source: selection_source,
        selection_reason: selection_reason,
        fallback_policy: fallback_policy,
        fallback_chain: fallback_chain
      )
    )
  end

  def expect_host_unavailable_log(run_id:, requested_host:, fallback_chain:, compatibility_failures:, health_failures:)
    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "process_run_queue.host_unavailable",
        agent_run_id: run_id,
        requested_host: requested_host,
        fallback_chain: fallback_chain,
        compatibility_failures: compatibility_failures,
        health_failures: health_failures
      )
    )
  end

  def stub_capacity_aware_preferred_run(project:)
    user = project.created_by
    user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: 20, max_parallel_agents_per_project: 20)
    stub_multi_host_registry(build_host_registry(fallback_policy: "capacity_aware"))
    stub_policy_decision(local_auto_decision)
    create_preferred_host_run(project: project, fallback: "capacity_aware")
  end

  def stub_host_capacity_snapshots(elguapo:, local:, aws:)
    snapshots = {
      "elguapo" => elguapo,
      "local" => local,
      "aws-runner-1" => aws
    }

    allow(Capacity::DockerSnapshot).to receive(:fetch) do |backend:|
      snapshots.fetch(backend.identifier).merge(
        backend_identifier: backend.identifier,
        docker_memory_bytes: 16.gigabytes
      )
    end
  end

  def expect_capacity_aware_decision(queued_run, planned_host:, decision_mode:)
    expect(queued_run.reload.external_metadata["planned_container_host"]).to eq(planned_host)
    expect(queued_run.reload.external_metadata.dig("host_placement_decision", "decision_mode")).to eq(decision_mode)
  end

  def provisioning_rate_denied_admission(available_at:)
    {
      allowed: false,
      reason: "global_provisioning_rate_limit",
      mode: "auto",
      selected_host: "local",
      host_active_count: 0,
      host_max_concurrent_runs: 2,
      host_available_slots: 2,
      available_slots: 0,
      global_active_count: 0,
      global_max_concurrent_executions: 50,
      global_available_slots: 50,
      effective_max_concurrent_runs: 5,
      available_memory_bytes: 16.gigabytes,
      estimated_memory_per_run_bytes: 4.gigabytes,
      reserved_agent_memory_bytes: 0,
      rate_limited_until: available_at
    }
  end

  def default_local_host_selection_result
    Containers::BackendScheduler::Result.new(
      candidate_hosts: [ "local" ],
      fallback_policy: "disabled",
      selection_source: "default",
      requested_host: "local",
      compatibility_failures: {},
      health_failures: {}
    )
  end

  def stub_unavailable_fallback_hosts(run, registry_bundle)
    disallowed = Containers::Provision::CompatibilityResult.new(
      compatible: false,
      error_message: "bind mounts unsupported"
    )
    allow(Containers::Provision).to receive(:compatibility_for)
      .with(agent_run: run, backend: registry_bundle.fetch(:elguapo_backend), worktree_path: nil)
      .and_return(disallowed)
    allow(registry_bundle.fetch(:local_backend)).to receive(:ping).and_raise(Docker::Error::DockerError, "local down")
    allow(registry_bundle.fetch(:aws_backend)).to receive(:ping).and_raise(Docker::Error::DockerError, "aws down")
  end

  describe "#perform" do
    it "falls back to another host with free slots when the preferred host is full" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 20, max_parallel_agents_per_project: 20)
      queued_run = create_preferred_host_run(project: project)
      create_host_saturation_runs("elguapo" => 4, "local" => 2)
      stub_multi_host_registry(build_host_registry)

      captured_input = nil
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        captured_input = input
        workflow_handle
      end

      described_class.new.perform

      # RDR-048 (#2947): the queue no longer eagerly persists container_host.
      # The planned placement is forwarded through the workflow input so the
      # provisioning activity can route to the right backend *before* a
      # container resource exists; container_host is updated only once the
      # backend creates/claims the resource. The admitted host is recorded in
      # external_metadata so active_count_for_host can attribute this claimed
      # run to the correct per-host ceiling during the claim window.
      expect(queued_run.reload.container_host).to be_nil
      expect(queued_run.reload.external_metadata["planned_container_host"]).to eq("aws-runner-1")
      expect(queued_run.temporal_workflow_id).to be_present
      expect(AgentRun.active_count_for_host("aws-runner-1")).to eq(1)
      expect(captured_input[:container_host]).to eq("aws-runner-1")
    end

    it "logs the selected host, selection reason, and fallback chain" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 20, max_parallel_agents_per_project: 20)
      queued_run = create_preferred_host_run(project: project)
      create_host_saturation_runs("elguapo" => 4, "local" => 2)
      stub_multi_host_registry(build_host_registry)
      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect_host_selected_log(
        run_id: queued_run.id,
        requested_host: "elguapo",
        selected_host: "aws-runner-1",
        selection_source: "preferred",
        selection_reason: "fallback",
        fallback_policy: "first_healthy",
        fallback_chain: [ "elguapo", "local", "aws-runner-1" ]
      )
    end

    it "keeps a host-saturated run queued without blocking other host candidates for the user" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 20, max_parallel_agents_per_project: 20)
      blocked_run = create_host_selected_run(project: project, host: "elguapo", created_at: 2.minutes.ago)
      eligible_run = create_host_selected_run(project: project, host: "aws-runner-1", created_at: 1.minute.ago)
      create_host_saturation_runs("elguapo" => 4)
      stub_multi_host_registry(build_host_registry)
      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect(blocked_run.reload.temporal_workflow_id).to be_nil
      expect(eligible_run.reload.temporal_workflow_id).to be_present
      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "process_run_queue.capacity_denied",
          reason: "host_hard_ceiling",
          selected_host: "elguapo"
        )
      )
    end

    it "logs compatibility and health failures when no host can be selected" do
      project = create(:project)
      queued_run = create_preferred_host_run(project: project)
      registry_bundle = build_host_registry
      stub_multi_host_registry(registry_bundle)
      stub_unavailable_fallback_hosts(queued_run, registry_bundle)
      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect_host_unavailable_log(
        run_id: queued_run.id,
        requested_host: "elguapo",
        fallback_chain: [ "elguapo", "local", "aws-runner-1" ],
        compatibility_failures: hash_including("elguapo" => "bind mounts unsupported"),
        health_failures: hash_including(
          "local" => a_string_including("local down"),
          "aws-runner-1" => a_string_including("aws down")
        )
      )
    end

    it "chooses the healthiest capacity-aware host instead of the first healthy fallback" do
      project = create(:project)
      queued_run = stub_capacity_aware_preferred_run(project: project)
      stub_host_capacity_snapshots(
        elguapo: { available: true, effective_agent_budget_bytes: 5.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] },
        local: { available: true, effective_agent_budget_bytes: 7.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] },
        aws: { available: true, effective_agent_budget_bytes: 9.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] }
      )
      allow(Rails.logger).to receive(:info)

      described_class.new.perform

      expect_capacity_aware_decision(queued_run, planned_host: "aws-runner-1", decision_mode: "capacity_aware")
      expect(queued_run.reload.external_metadata.dig("host_placement_decision", "selected_by_capacity")).to be(true)
      expect_host_selected_log(
        run_id: queued_run.id,
        requested_host: "elguapo",
        selected_host: "aws-runner-1",
        selection_source: "preferred",
        selection_reason: "capacity_aware",
        fallback_policy: "capacity_aware",
        fallback_chain: [ "elguapo", "local", "aws-runner-1" ]
      )
    end

    it "falls back to manual first-healthy ordering when capacity snapshots are degraded" do
      project = create(:project)
      queued_run = stub_capacity_aware_preferred_run(project: project)
      stub_host_capacity_snapshots(
        elguapo: { available: false, reason: "docker_timeout", degraded_reasons: [ "docker_timeout" ], snapshot_at: Time.current, confidence: "low" },
        local: { available: true, effective_agent_budget_bytes: 9.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] },
        aws: { available: true, effective_agent_budget_bytes: 9.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] }
      )

      described_class.new.perform

      expect_capacity_aware_decision(queued_run, planned_host: "elguapo", decision_mode: "capacity_aware_fallback")
    end

    it "falls back to manual first-healthy ordering when capacity snapshots are stale" do
      project = create(:project)
      queued_run = stub_capacity_aware_preferred_run(project: project)
      stub_host_capacity_snapshots(
        elguapo: { available: false, reason: "docker_unavailable", degraded_reasons: [ "stale_cache", "docker_unavailable" ], snapshot_at: 3.minutes.ago, confidence: "low" },
        local: { available: true, effective_agent_budget_bytes: 9.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] },
        aws: { available: true, effective_agent_budget_bytes: 9.gigabytes, snapshot_at: Time.current, confidence: "high", degraded_reasons: [] }
      )

      described_class.new.perform

      expect_capacity_aware_decision(queued_run, planned_host: "elguapo", decision_mode: "capacity_aware_fallback")
    end

    it "starts the oldest queued run when capacity is available" do # @spec TEMPORAL-ORCHESTRATION-005
      queued_run = create(:agent_run, :queued, created_at: 2.minutes.ago)
      create(:agent_run, :queued, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: queued_run.id),
        hash_including(
          task_queue: "paid-agent-tasks",
          priority: temporal_priority_for(queued_run)
        )
      ).and_return(workflow_handle)

      job.perform

      queued_run.reload
      expect(queued_run.status).to eq("running")
      expect(queued_run.started_at).to be_nil
      expect(queued_run.temporal_workflow_id).to be_present
      expect(LiveDashboardBroadcastJob).to have_been_enqueued.with(
        queued_run.project.account_id,
        queued_run.id,
        refresh_queue_preview: true
      )
    end

    it "starts multiple queued runs up to user capacity" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      older = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 2.minutes.ago)
      newer = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).twice.and_return(workflow_handle)

      described_class.new.perform

      expect(older.reload.status).to eq("running")
      expect(newer.reload.status).to eq("running")
    end

    it "keeps auto-mode runs queued when Docker capacity is insufficient" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)
      queued_run = create(:agent_run, :queued, project: project)
      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(auto_mode_snapshot)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.temporal_workflow_id).to be_nil
      expect(queued_run.status).to eq("queued")
    end

    it "bulk-skips an auto-mode user's backlog when Docker capacity is insufficient" do
      stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)
      10.times do |i|
        create(:agent_run, :queued, project: blocked_project, created_at: (20 - i).minutes.ago)
      end

      eligible_project = create(:project)
      eligible_run = create(:agent_run, :queued, project: eligible_project, created_at: 1.minute.ago)

      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(auto_mode_snapshot)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ eligible_run.id ])
    end

    it "keeps project-level blocking scoped when auto mode degrades to manual admission" do
      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil, max_parallel_agents_per_project: 1)
      create(:agent_run, :running, project: blocked_project)
      create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago)
      eligible_project = create(:project, account: blocked_project.account, created_by: blocked_user)
      eligible_run = create(:agent_run, :queued, project: eligible_project, created_at: 1.minute.ago)
      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(available: false, reason: "docker_timeout",
        snapshot_at: Time.current, confidence: "low")
      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end
      described_class.new.perform
      expect(started_ids).to eq([ eligible_run.id ])
    end

    it "reuses one Docker snapshot per queue pass" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)
      create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 2.minutes.ago)
      create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)
      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
        available: true,
        effective_agent_budget_bytes: 16 * 1024 * 1024 * 1024,
        snapshot_at: Time.current,
        confidence: "high",
        docker_memory_bytes: 32 * 1024 * 1024 * 1024
      )

      described_class.new.perform

      expect(Capacity::DockerSnapshot).to have_received(:fetch).once
    end

    it "caches reserved local agent memory across auto-mode admissions in one queue pass" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)
      running_run = create(:agent_run, :running, project: project, container_host: Containers::LOCAL_BACKEND_KEY.to_s)
      create(:container_metric, agent_run: running_run, memory_limit_bytes: 6.gigabytes, recorded_at: 1.minute.ago)
      create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 2.minutes.ago)
      create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)
      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
        available: true,
        effective_agent_budget_bytes: 20.gigabytes,
        snapshot_at: Time.current,
        confidence: "high",
        docker_memory_bytes: 32.gigabytes
      )

      queries = capture_queries do
        described_class.new.perform
      end

      expect(queries.grep(/FROM "container_metrics"/).size).to eq(1)
    end

    it "accounts for manual-mode run memory within an auto-mode queue pass" do
      # Scenario: auto-mode user A has two queued runs; manual-mode user B has one.
      # Docker budget is exactly 2 × DEFAULT_ESTIMATED_MEMORY_BYTES (4 GB each = 8 GB).
      # After A's first run starts (4 GB reserved) and B's manual run starts
      # (4 GB — now also reserved with fix), A's second run must be blocked.
      auto_project = create(:project)
      auto_user = auto_project.created_by
      auto_user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: nil)

      manual_project = create(:project)
      manual_user = manual_project.created_by
      manual_user.settings.update!(max_concurrent_runs: 10)

      auto_run1 = create(:agent_run, :queued, project: auto_project, created_at: 5.minutes.ago)
      manual_run  = create(:agent_run, :queued, project: manual_project, created_at: 3.minutes.ago)
      auto_run2   = create(:agent_run, :queued, project: auto_project, created_at: 1.minute.ago)

      allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
        available: true,
        effective_agent_budget_bytes: 2 * Capacity::RunAdmission::DEFAULT_ESTIMATED_MEMORY_BYTES,
        snapshot_at: Time.current,
        confidence: "high",
        docker_memory_bytes: 16.gigabytes
      )

      described_class.new.perform

      expect(auto_run1.reload.temporal_workflow_id).to be_present
      expect(manual_run.reload.temporal_workflow_id).to be_present
      expect(auto_run2.reload.temporal_workflow_id).to be_nil
    end

    it "stops when user capacity is exhausted" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 2)
      create(:agent_run, :running, project: project)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does nothing when no queued runs exist" do
      create(:agent_run, :running)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform
    end

    it "uses the account id as the Temporal fairness key" do
      queued_run = create(:agent_run, :queued)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: queued_run.id),
        hash_including(
          priority: temporal_priority_for(queued_run)
        )
      ).and_return(workflow_handle)

      job.perform
    end

    it "keeps the account id as the Temporal fairness key for strict-priority accounts" do
      queued_run = create(:agent_run, :queued)
      queued_run.project.account.tenant_setting!.update!(queue_fairness_mode: "strict_priority")

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: queued_run.id),
        hash_including(
          priority: temporal_priority_for(queued_run)
        )
      ).and_return(workflow_handle)

      job.perform

      expect(temporal_priority_for(queued_run).fairness_key).to eq(queued_run.project.account_id.to_s)
    end

    it "keeps strict-priority accounts isolated in Temporal fairness buckets" do
      first_run, second_run = create_strict_priority_vs_strict_priority_runs

      expect(temporal_priority_for(first_run).fairness_key).to eq(first_run.project.account_id.to_s)
      expect(temporal_priority_for(second_run).fairness_key).to eq(second_run.project.account_id.to_s)
      expect(temporal_priority_for(first_run).fairness_key).not_to eq(temporal_priority_for(second_run).fairness_key)
    end

    it "does not let a strict-priority account globally outrank an idle fair-share account" do
      _strict_run, fair_run = create_strict_priority_vs_fair_share_runs

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.first).to eq(fair_run.id)
    end

    it "does not let one strict-priority account globally outrank another account's idle work" do
      _busy_run, idle_run = create_strict_priority_vs_strict_priority_runs

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.first).to eq(idle_run.id)
    end

    it "processes runs in FIFO order within the same priority" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      older = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
      newer = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ older.id ])
      expect(older.reload.status).to eq("running")
      expect(newer.reload.status).to eq("queued")
    end

    it "starts manual runs before automatic runs regardless of creation time" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      auto = create(:agent_run, :queued, project: project, trigger_type: "automatic", created_at: 3.minutes.ago)
      manual = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id ])
      expect(manual.reload.status).to eq("running")
      expect(auto.reload.status).to eq("queued")
    end

    it "starts an older queued manual run before a later auto-continue followup" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      manual = create(:agent_run, :queued, :manual, project: project, created_at: 2.minutes.ago)
      followup_issue = create(:issue, project: project)
      auto_continue = create(:agent_run, :queued, :automatic, :existing_pr,
        project: project, issue: followup_issue, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id ])
      expect(manual.reload.status).to eq("running")
      expect(auto_continue.reload.status).to eq("queued")
    end

    it "starts review runs before create_pr runs when scheduler priorities tie" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      create_pr_run = create(:agent_run, :queued, :automatic, :existing_pr,
        project: project, goal: "create_pr", source_pull_request_number: 42, created_at: 2.minutes.ago)
      review_run = create(:agent_run, :queued, :automatic, :review_goal,
        project: project, source_pull_request_number: 43, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ review_run.id ])
      expect(review_run.reload.temporal_workflow_id).to be_present
      expect(create_pr_run.reload.temporal_workflow_id).to be_nil
    end

    it "uses spare capacity for lower-priority work after claiming a manual run" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      manual = create(:agent_run, :queued, :manual, project: project, goal: "review", source_pull_request_number: 42,
        created_at: 2.minutes.ago)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, :automatic, project: project, issue: p1_issue, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id, p1_run.id ])
      expect(manual.reload.temporal_workflow_id).to be_present
      expect(p1_run.reload.temporal_workflow_id).to be_present
    end

    it "uses spare capacity while higher-priority work from the same project is claimed" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      create(:agent_run, :queued, :manual, project: project, goal: "review", source_pull_request_number: 42,
        temporal_workflow_id: AgentRun::CLAIMED_SENTINEL)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, :automatic, project: project, issue: p1_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p1_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p1_run.reload.temporal_workflow_id).to be_present
    end

    it "uses spare capacity for lower-priority work while higher-priority work from the same project is running" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      p1_issue = create(:issue, project: project, github_number: 100, labels: [ "P1" ])
      create(:agent_run, :running, project: project, trigger_type: "automatic", issue: p1_issue)
      p2_issue = create(:issue, project: project, github_number: 200, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p2_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_present
    end

    it "does not start lower-priority work when the same project is at its concurrency cap" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10, max_parallel_agents_per_project: 3)

      3.times do |i|
        p1_issue = create(:issue, project: project, github_number: 100 + i, labels: [ "P1" ])
        create(:agent_run, :running, project: project, trigger_type: "automatic", issue: p1_issue)
      end
      p2_issue = create(:issue, project: project, github_number: 200, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_nil
    end

    it "does not let paused or completed higher-priority work block lower-priority work" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      # A P1 blocked/paused (e.g. quality pause or awaiting input) and a P1
      # whose run already finished (PR now sitting in review) are not in
      # flight, so neither should preempt runnable lower-priority work.
      paused_p1 = create(:issue, project: project, github_number: 1, labels: [ "P1" ])
      create(:agent_run, :paused, project: project, trigger_type: "automatic", issue: paused_p1)
      done_p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])
      create(:agent_run, :completed, project: project, trigger_type: "automatic", issue: done_p1)

      p2_issue = create(:issue, project: project, github_number: 3, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p2_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_present
    end

    it "lets a queued run start when only lower-priority work is in flight" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      # A lower-priority auto-pick run is in flight; it must not block higher-priority queued work.
      create(:agent_run, :running, project: project, trigger_type: "automatic")
      p2_issue = create(:issue, project: project, github_number: 200, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p2_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_present
    end

    it "uses spare capacity for equal-priority queued work from the same project" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      running_p1 = create(:issue, project: project, github_number: 10, labels: [ "P1" ])
      create(:agent_run, :running, project: project, trigger_type: "automatic", issue: running_p1)
      queued_p1 = create(:issue, project: project, github_number: 11, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: queued_p1)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p1_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p1_run.reload.temporal_workflow_id).to be_present
    end

    it "marks run as failed and continues when workflow start fails" do
      failing_run = create(:agent_run, :queued, created_at: 2.minutes.ago)
      good_run = create(:agent_run, :queued, created_at: 1.minute.ago)

      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        raise StandardError, "Connection refused" if input[:agent_run_id] == failing_run.id
        workflow_handle
      end

      described_class.new.perform

      expect(failing_run.reload.status).to eq("failed")
      expect(failing_run.configuration_bundle).to be_present
      expect(failing_run.reload.error_message).to include("Connection refused")
      # temporal_workflow_id is intentionally kept on failure so
      # StaleRunDetectorJob can cancel a potentially-orphaned workflow
      # (e.g. when start_workflow raises due to a network timeout but
      # the workflow actually started server-side).
      expect(failing_run.reload.temporal_workflow_id).to be_present
      expect(good_run.reload.status).to eq("running")
    end

    it "enqueues finished-run followups when workflow start fails" do
      failing_run = create(:agent_run, :queued)

      allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "Connection refused")

      described_class.new.perform

      expect(QualityMetricsCollectionJob).to have_been_enqueued.with(failing_run.id)
      expect(AnomalyDetectionJob).to have_been_enqueued.with(failing_run.id)
      expect(DashboardBroadcastJob).to have_been_enqueued.with(failing_run.project.account_id)
    end

    it "admits a claimed run even when unrelated validations drift after queueing" do
      queued_run = create(:agent_run, :queued)
      other_user = create(:user)
      queued_run.update_columns(initiating_user_id: other_user.id)
      allow(ConfigurationBundles::AssignToRun).to receive(:call)

      result = job.send(:start_claimed_run, queued_run)

      expect(result).to be(true)
      expect(queued_run.reload.status).to eq("running")
      expect(queued_run.temporal_workflow_id).to be_present
      expect(queued_run.started_at).to be_nil
    end

    it "fails run when project owner cannot be resolved" do
      job = described_class.new
      project = create(:project)
      queued_run = create(:agent_run, :queued, project: project)
      allow(project).to receive(:effective_owner).and_return(nil)
      allow(queued_run).to receive(:project).and_return(project)
      allow(job).to receive(:next_queued_run_for_scheduler).and_return(queued_run, nil)

      expect(temporal_client).not_to receive(:start_workflow)

      job.perform

      expect(queued_run.reload.status).to eq("failed")
      expect(queued_run.error_message).to include("Cannot resolve project owner")
    end

    it "re-queues run when user concurrency limit is reached" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does not start a run when the project parallel limit is already reached" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10, max_parallel_agents_per_project: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does not start queued runs when the account's scheduler is paused" do
      paused_account = create(:account, scheduler_paused_at: Time.current)
      paused_project = create(:project, account: paused_account, created_by: create(:user, account: paused_account))
      paused_run = create(:agent_run, :queued, project: paused_project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(paused_run.reload.status).to eq("queued")
    end

    it "still starts queued runs for accounts whose scheduler is not paused" do
      paused_account = create(:account, scheduler_paused_at: Time.current)
      paused_project = create(:project, account: paused_account, created_by: create(:user, account: paused_account))
      paused_run = create(:agent_run, :queued, project: paused_project, created_at: 2.minutes.ago)

      active_project = create(:project)
      active_run = create(:agent_run, :queued, project: active_project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ active_run.id ])
      expect(active_run.reload.status).to eq("running")
      expect(paused_run.reload.status).to eq("queued")
    end

    it "skips blocked user and starts runs for other users" do
      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: blocked_project)
      blocked_run = create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago)

      other_project = create(:project)
      eligible_run = create(:agent_run, :queued, project: other_project, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

      described_class.new.perform

      expect(blocked_run.reload.status).to eq("queued")
      expect(eligible_run.reload.status).to eq("running")
    end

    it "bulk-skips a blocked owner's backlog so later runnable owners are still reached" do
      stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: blocked_project)
      10.times do |i|
        create(:agent_run, :queued, project: blocked_project, created_at: (20 - i).minutes.ago)
      end

      eligible_project = create(:project)
      eligible_run = create(:agent_run, :queued, project: eligible_project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ eligible_run.id ])
    end

    it "force-fails an unclaimable run at the queue head and continues dispatching the rest" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 2)

      # Reproduce the production scenario: a bound run whose agent_type drifted
      # out of AgentRun::AGENT_TYPES (written via a validation-bypassing path).
      # It is already bound to a runner, so BindRunner does not overwrite the
      # bad value. Claiming calls update!, which re-validates and raises
      # RecordInvalid — without the rescue this stalls every dispatch tick.
      poisoned = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
      poisoned.update_columns(agent_type: "bogus_invalid_type", runner_id: create(:runner, user: user).id)
      eligible = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      expect { described_class.new.perform }.not_to raise_error

      expect(poisoned.reload.status).to eq("failed")
      expect(poisoned.reload.error_message).to match(/Agent type/i)
      expect(started_ids).to include(eligible.id)
    end

    it "does not start queued runs when user is at capacity" do
      project = create(:project, auto_pick_enabled: true)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "never exceeds per-user capacity even when starting multiple queued runs" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 4, max_parallel_agents_per_project: 10)

      runs = 6.times.map { |i| create(:agent_run, :queued, project: project, created_at: (6 - i).minutes.ago) }

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.length).to eq(4)
      runs.first(4).each { |r| expect(r.reload.temporal_workflow_id).to be_present }
      runs.last(2).each { |r| expect(r.reload.temporal_workflow_id).to be_nil }
    end

    it "rechecks capacity from DB after each start and respects concurrent external starts" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 2)

      run1 = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
      _run2 = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)
      _run3 = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        if input[:agent_run_id] == run1.id
          create(:agent_run, :running, project: project)
        end
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.length).to eq(1)
    end

    it "does not seed auto-pick work while dequeuing" do
      project = create(:project, auto_pick_enabled: true)
      create(:issue, project: project)

      allow(Issues::BulkEnqueueEligible).to receive(:call)

      described_class.new.perform

      expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
    end

    it "starts a queued manual run alongside running auto-pick work" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 4, max_parallel_agents_per_project: 4)

      3.times { create(:agent_run, :running, project: project, trigger_type: "automatic") }
      manual_run = create(:agent_run, :queued, project: project, trigger_type: "manual")

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: manual_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(manual_run.reload.status).to eq("running")
    end

    it "fails a budget-blocked run without consuming capacity or counting as a failure" do
      blocked_project = create(:project)
      user = blocked_project.created_by
      user.settings.update!(max_concurrent_runs: 2)
      create(:cost_budget, :hard_stop, :daily, project: blocked_project,
        limit_cents: 100, current_usage_cents: 200,
        period_started_at: Time.current.beginning_of_day)

      unblocked_project = create(:project, account: blocked_project.account, created_by: user)

      blocked_run = create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago)
      normal_run = create(:agent_run, :queued, project: unblocked_project, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

      described_class.new.perform

      expect(blocked_run.reload.status).to eq("failed")
      expect(blocked_run.error_message).to include("Budget enforcement")
      expect(normal_run.reload.status).to eq("running")
    end

    context "with RDR-032 dequeue-time eligibility recheck" do
      # Issues are created in their ineligible state BEFORE the queued run
      # so update callbacks (closed/paused label sync, orphan-run
      # cancellation) don't pre-empt the recheck under test.
      it "cancels a queued auto-pick run whose issue carries a skip label and starts the next eligible run" do
        project = create(:project, auto_pick_enabled: true)
        ineligible_issue = create(:issue, project: project, github_state: "open", labels: [ "planning" ],
          github_number: 1)
        ineligible_run = create(:agent_run, :queued, :automatic, project: project,
          issue: ineligible_issue, goal: "create_pr", auto_pick: true, created_at: 2.minutes.ago)

        eligible_issue = create(:issue, project: project, github_state: "open", github_number: 2)
        eligible_run = create(:agent_run, :queued, :automatic, project: project,
          issue: eligible_issue, goal: "create_pr", auto_pick: true, created_at: 1.minute.ago)

        started_ids = []
        allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
          started_ids << input[:agent_run_id]
          workflow_handle
        end

        described_class.new.perform

        expect(ineligible_run.reload.status).to eq("cancelled")
        expect(eligible_run.reload.temporal_workflow_id).to be_present
        expect(started_ids).to eq([ eligible_run.id ])
      end

      it "cancels a run whose issue is in a paid_state skip state" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project, github_state: "open", paid_state: "needs_input")
        run = create(:agent_run, :queued, :automatic, project: project,
          issue: issue, goal: "create_pr", auto_pick: true)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(run.reload.status).to eq("cancelled")
      end

      it "cancels a run whose issue is blocked by an open dependency" do
        project = create(:project, auto_pick_enabled: true)
        dependent = create(:issue, project: project, github_state: "open")
        blocker = create(:issue, project: project, github_state: "open")
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
        run = create(:agent_run, :queued, :automatic, project: project,
          issue: dependent, goal: "create_pr", auto_pick: true)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(run.reload.status).to eq("cancelled")
      end

      it "cancels a run whose issue was closed after seeding" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project, github_state: "closed")
        run = create(:agent_run, :queued, :automatic, project: project,
          issue: issue, goal: "create_pr", auto_pick: true)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(run.reload.status).to eq("cancelled")
      end

      it "starts an eligible auto-pick run unchanged" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project, github_state: "open")
        run = create(:agent_run, :queued, :automatic, project: project,
          issue: issue, goal: "create_pr", auto_pick: true)

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(run.reload.temporal_workflow_id).to be_present
        expect(run.reload.status).to eq("running")
      end

      it "does not recheck a manual run even if its issue is ineligible" do
        project = create(:project)
        issue = create(:issue, project: project, github_state: "open", labels: [ "planning" ])
        run = create(:agent_run, :queued, :manual, project: project,
          issue: issue, goal: "create_pr")

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(run.reload.status).to eq("running")
        expect(run.reload.temporal_workflow_id).to be_present
      end
    end

    context "when GitHub circuit is open" do
      it "skips dispatching entirely" do
        create(:github_health_state, :circuit_open)
        create(:agent_run, :queued)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.skipped_github_unavailable",
          reason: "circuit_open"
        ))
      end

      it "attempts circuit recovery when timeout has elapsed" do
        state = create(:github_health_state, circuit_state: "open",
          circuit_opened_at: 10.minutes.ago, failure_count: 5)
        create(:agent_run, :queued)

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(state.reload.circuit_state).to eq("half_open")
      end
    end

    context "when GitHub is rate limited" do
      let(:reset_at) { 30.minutes.from_now }
      let(:blocked_project) { create(:project) }
      let(:runnable_project) { create(:project) }
      let!(:blocked_run) { create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago) }
      let!(:runnable_run) { create(:agent_run, :queued, project: runnable_project, created_at: 1.minute.ago) }

      before do
        create(:github_health_state, endpoint: blocked_project.github_health_endpoint, rate_limited_until: reset_at)
        allow(Rails.logger).to receive(:info)
      end

      it "skips only runs for projects using the rate-limited credential" do
        expect(temporal_client).to receive(:start_workflow).with(
          Workflows::AgentExecutionWorkflow,
          hash_including(agent_run_id: runnable_run.id),
          hash_including(task_queue: "paid-agent-tasks")
        ).and_return(workflow_handle)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.skipped_github_unavailable",
          project_id: blocked_project.id,
          reason: "rate_limited",
          available_at: reset_at.iso8601
        ))
        expect(blocked_run.reload.status).to eq("queued")
        expect(runnable_run.reload.temporal_workflow_id).to be_present
      end

      it "resumes dispatching once the rate-limit window has elapsed" do
        project = create(:project)
        create(:github_health_state, endpoint: project.github_health_endpoint, rate_limited_until: 1.minute.ago)
        create(:agent_run, :queued, project: project)

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform
      end
    end

    it "includes workflow input fields from the agent run" do
      issue = create(:issue)
      queued_run = create(:agent_run, :queued,
        project: issue.project,
        issue: issue,
        custom_prompt: "Fix the bug",
        source_pull_request_number: 42)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(
          project_id: queued_run.project_id,
          agent_run_id: queued_run.id,
          issue_id: issue.id,
          custom_prompt: "Fix the bug",
          source_pull_request_number: 42
        ),
        anything
      ).and_return(workflow_handle)

      described_class.new.perform
    end

    context "when runner preflight fails" do
      it "skips the run when the runner circuit is open" do
        project = create(:project)
        user = project.created_by
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "circuit_open"
        ))
      end

      it "skips the run when the runner is rate limited" do
        project = create(:project)
        user = project.created_by
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "rate_limited"
        ))
      end

      it "falls back to a healthy runner when an API-key runner has no secret" do
        project = create(:project)
        user = project.created_by
        provider_api_key = create(:provider_api_key, user: user)
        runner = create(:runner, user: user, runner_key: "cursor", auth_type: "api_key", provider_api_key: provider_api_key)
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        allow(Runners::PreflightCheck).to receive(:call).and_call_original
        allow(Runners::PreflightCheck).to receive(:call)
          .with(runner: runner, user: user)
          .and_return(Runners::PreflightCheck::Result.new(pass?: false, reason: "missing_api_key", runner_id: runner.id))

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        queued_run.reload
        expect(queued_run.runner_id).to eq(claude_runner.id)
        expect(queued_run.temporal_workflow_id).to be_present
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "missing_api_key"
        ))
      end

      it "starts a run from another project when one runner fails preflight" do
        blocked_project = create(:project)
        blocked_user = blocked_project.created_by
        blocked_runner = blocked_user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: blocked_user, runner_name: blocked_runner.state_key)
        blocked_run = create(:agent_run, :queued, project: blocked_project, runner: blocked_runner, created_at: 2.minutes.ago)

        other_project = create(:project)
        other_run = create(:agent_run, :queued, project: other_project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(blocked_run.reload.status).to eq("queued")
        expect(other_run.reload.status).to eq("running")
        expect(other_run.reload.temporal_workflow_id).to be_present
      end

      it "bulk-skips runs with the same failed runner without repeated preflight checks" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 10)
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key)

        10.times { |i| create(:agent_run, :queued, project: project, runner: runner, created_at: (20 - i).minutes.ago) }

        allow(Runners::PreflightCheck).to receive(:call).and_call_original

        described_class.new.perform

        expect(Runners::PreflightCheck).to have_received(:call).once
      end

      it "reroutes a pinned run to a healthy alternative when its runner is rate limited" do
        project = create(:project)
        user = project.created_by
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: claude_runner.state_key)
        codex_runner = create(:runner, user: user, runner_key: "codex")
        queued_run = create(:agent_run, :queued, project: project, runner: claude_runner)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        queued_run.reload
        expect(queued_run.status).to eq("running")
        expect(queued_run.runner_id).to eq(codex_runner.id)
        expect(queued_run.agent_type).to eq("codex")
        expect(queued_run.temporal_workflow_id).to be_present
        expect(queued_run.runner_switches).to eq(1)
      end

      it "reroutes a manually pinned run when its runner circuit is open" do
        project = create(:project)
        user = project.created_by
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: user, runner_name: claude_runner.state_key)
        codex_runner = create(:runner, user: user, runner_key: "codex")
        queued_run = create(:agent_run, :queued, project: project, runner: claude_runner, trigger_type: "manual")

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(queued_run.reload.runner_id).to eq(codex_runner.id)
      end

      it "restores the pin and keeps the run queued when no healthy alternative exists" do
        project = create(:project)
        user = project.created_by
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        queued_run.reload
        expect(queued_run.status).to eq("queued")
        expect(queued_run.runner_id).to eq(runner.id)
      end

      # @spec RUNNER-SCHED-005, RUNNER-SCHED-008 — pinned runs blocked by a
      # time-window restriction must be rerouted (or parked), not dispatched.
      context "when a pinned runner is blocked by a time-window restriction" do
        def block_config(start_h, end_h)
          { "mode" => "block", "timezone" => "UTC",
            "windows" => [ { "start_hour" => start_h, "end_hour" => end_h } ] }
        end

        it "reroutes a pinned run to a healthy alternative inside a block window" do
          project = create(:project)
          user = project.created_by
          claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
          claude_runner.update_columns(time_restrictions: block_config(1, 4))
          codex_runner = create(:runner, user: user, runner_key: "codex")
          queued_run = create(:agent_run, :queued, project: project, runner: claude_runner)

          expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

          travel_to Time.utc(2026, 1, 1, 2, 0) do
            described_class.new.perform
          end

          queued_run.reload
          expect(queued_run.runner_id).to eq(codex_runner.id)
          expect(queued_run.temporal_workflow_id).to be_present
        end

        it "parks the run when every alternative is also time-window-blocked" do
          project = create(:project)
          user = project.created_by
          claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
          claude_runner.update_columns(time_restrictions: block_config(1, 4))
          codex_runner = create(:runner, user: user, runner_key: "codex")
          codex_runner.update_columns(time_restrictions: block_config(1, 6))
          queued_run = create(:agent_run, :queued, project: project, runner: claude_runner)

          expect(temporal_client).not_to receive(:start_workflow)

          travel_to Time.utc(2026, 1, 1, 2, 0) do
            described_class.new.perform
          end

          queued_run.reload
          expect(queued_run.status).to eq("rate_limited")
          expect(queued_run.rate_limited_until).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
        end

        it "parks the run even when the pinned runner is the only eligible runner" do
          project = create(:project)
          user = project.created_by
          claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
          claude_runner.update_columns(time_restrictions: block_config(1, 4))
          # Disable every other runner so claude is the only eligible one. Uses
          # update_columns to bypass the "last runner" validation.
          user.runners.kept_only.where.not(id: claude_runner.id).each do |r|
            r.update_columns(enabled_for_agent_runs: false)
          end
          queued_run = create(:agent_run, :queued, project: project, runner: claude_runner)

          expect(temporal_client).not_to receive(:start_workflow)

          travel_to Time.utc(2026, 1, 1, 2, 0) do
            described_class.new.perform
          end

          queued_run.reload
          expect(queued_run.status).to eq("rate_limited")
          expect(queued_run.rate_limited_until).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
        end

        it "caches the park decision so TimeWindowPark is bounded by reroute context count" do
          stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 8)

          project = create(:project)
          user = project.created_by
          user.settings.update!(max_concurrent_runs: 10)
          claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
          claude_runner.update_columns(time_restrictions: block_config(1, 4))
          codex_runner = create(:runner, user: user, runner_key: "codex")
          codex_runner.update_columns(time_restrictions: block_config(1, 4))

          3.times { |i| create(:agent_run, :queued, project: project, runner: claude_runner, created_at: (10 - i).minutes.ago) }

          allow(Runners::TimeWindowPark).to receive(:call).and_call_original

          travel_to Time.utc(2026, 1, 1, 2, 0) do
            described_class.new.perform
          end

          # Two distinct reroute contexts arise (claude pin, then codex after the
          # two-step reroute), so TimeWindowPark is evaluated at most twice — not
          # once per run. The third run reuses the cached park decision.
          expect(Runners::TimeWindowPark).to have_received(:call).at_most(:twice)
          expect(AgentRun.where(status: "rate_limited").count).to eq(3)
        end
      end

      it "caches reroute resolution so BindRunner is called once per blocked runner context" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 10)
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: claude_runner.state_key)
        codex_runner = create(:runner, user: user, runner_key: "codex")

        3.times { |i| create(:agent_run, :queued, project: project, runner: claude_runner, created_at: (10 - i).minutes.ago) }

        allow(AgentRuns::BindRunner).to receive(:call).and_call_original

        described_class.new.perform

        expect(AgentRuns::BindRunner).to have_received(:call).once
        expect(AgentRun.where(runner_id: codex_runner.id).count).to eq(3)
      end

      it "does not reuse a cached reroute across projects with different resolver context" do
        owner = create(:user, :owner)
        account = owner.account
        first_project = create(:project, account: account, created_by: owner,
          model_preferences: { "preferred_agent_type" => "codex" })
        second_project = create(:project, account: account, created_by: owner,
          model_preferences: { "preferred_agent_type" => "cursor" })
        claude_runner = owner.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: owner, runner_name: claude_runner.state_key)
        codex_runner = create(:runner, user: owner, runner_key: "codex")
        cursor_runner = create(:runner, user: owner, runner_key: "cursor")
        codex_run = create(:agent_run, :queued, project: first_project, runner: claude_runner, created_at: 2.minutes.ago)
        cursor_run = create(:agent_run, :queued, project: second_project, runner: claude_runner, created_at: 1.minute.ago)

        allow(AgentRuns::BindRunner).to receive(:call).and_call_original

        described_class.new.perform

        expect(AgentRuns::BindRunner).to have_received(:call).twice
        expect(codex_run.reload.runner_id).to eq(codex_runner.id)
        expect(cursor_run.reload.runner_id).to eq(cursor_runner.id)
      end

      it "logs runner switch in audit trail when rerouting" do
        project = create(:project)
        user = project.created_by
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: claude_runner.state_key)
        create(:runner, user: user, runner_key: "codex")
        queued_run = create(:agent_run, :queued, project: project, runner: claude_runner)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        queued_run.reload
        log_entry = queued_run.agent_run_logs.find { |l| l.content.include?("Runner fallback") }
        expect(log_entry).to be_present
        expect(log_entry.content).to include("dispatch_reroute")
        expect(queued_run.runner_switches).to eq(1)
      end

      it "skips reroute audit logging when a routing key cannot be resolved" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

        project = create(:project)
        user = project.created_by
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: claude_runner.state_key)
        create(:runner, user: user, runner_key: "codex")
        first_run = create(:agent_run, :queued, project: project, runner: claude_runner, created_at: 2.minutes.ago)
        second_run = create(:agent_run, :queued, project: project, runner: claude_runner, created_at: 1.minute.ago)
        job = described_class.new

        allow(job).to receive(:runner_routing_key).and_call_original
        allow(job).to receive(:runner_routing_key).with(claude_runner.id).and_return(nil)

        job.perform

        expect(first_run.reload.runner_switches).to eq(0)
        expect(second_run.reload.runner_switches).to eq(0)
        expect(first_run.agent_run_logs.none? { |log| log.content.include?("dispatch_reroute") }).to be(true)
        expect(second_run.agent_run_logs.none? { |log| log.content.include?("dispatch_reroute") }).to be(true)
      end
    end

    # @spec RUNNER-SCHED-008 — runner-agnostic (auto-pick) runs whose every
    # eligible runner is time-window-blocked are parked until a window opens.
    context "when all runners are time-window-blocked for an auto-pick run" do
      it "parks an unbound run until the earliest window opens" do
        project = create(:project)
        user = project.created_by
        claude_runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        claude_runner.update_columns(time_restrictions: {
          "mode" => "block", "timezone" => "UTC",
          "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
        })
        # An auto-pick run has no runner pinned (runner_id nil).
        queued_run = create(:agent_run, :queued, project: project, runner: nil, agent_type: "claude_code")

        expect(temporal_client).not_to receive(:start_workflow)

        travel_to Time.utc(2026, 1, 1, 2, 0) do
          described_class.new.perform
        end

        queued_run.reload
        expect(queued_run.status).to eq("rate_limited")
        expect(queued_run.rate_limited_until).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
      end
    end

    context "when account create_pr concurrency cap is configured" do
      it "does not start create_pr runs when account is at the create_pr cap" do
        project = create(:project)
        create(:tenant_setting, account: project.account, max_concurrent_create_pr_runs: 2)

        create(:agent_run, :running, project: project, goal: "create_pr")
        create(:agent_run, :running, project: project, goal: "create_pr")
        queued_run = create(:agent_run, :queued, project: project, goal: "create_pr")

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "still starts non-create_pr runs when create_pr cap is reached" do
        project = create(:project)
        create(:tenant_setting, account: project.account, max_concurrent_create_pr_runs: 1)

        create(:agent_run, :running, project: project, goal: "create_pr")
        create_pr_run = create(:agent_run, :queued, project: project, goal: "create_pr", created_at: 2.minutes.ago)
        other_run = create(:agent_run, :queued, project: project, goal: "create_issue", created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(create_pr_run.reload.status).to eq("queued")
        expect(other_run.reload.temporal_workflow_id).to be_present
      end

      it "starts create_pr runs for accounts with available capacity" do
        capped_project = create(:project)
        create(:tenant_setting, account: capped_project.account, max_concurrent_create_pr_runs: 1)
        create(:agent_run, :running, project: capped_project, goal: "create_pr")
        capped_run = create(:agent_run, :queued, project: capped_project, goal: "create_pr", created_at: 2.minutes.ago)

        open_project = create(:project)
        open_run = create(:agent_run, :queued, project: open_project, goal: "create_pr", created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(capped_run.reload.status).to eq("queued")
        expect(open_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "when the dispatch circuit breaker is open for an account" do
      it "blocks all queued runs for that account in a single pass" do
        account = create(:account)
        project = create(:project, account: account)
        create(:dispatch_circuit_breaker, :open, account: account)
        runs = Array.new(3) { create(:agent_run, :queued, project: project) }

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(runs.map { |run| run.reload.status }).to all(eq("queued"))
      end

      it "does not starve other accounts when a halted account has a deep backlog" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 4)

        halted_account = create(:account)
        halted_project = create(:project, account: halted_account)
        create(:dispatch_circuit_breaker, :open, account: halted_account)
        # More halted-account runs than the iteration budget so only the peek
        # exclusion (not in-memory skipping) lets the other account through.
        Array.new(5) { |i| create(:agent_run, :queued, project: halted_project, created_at: (20 - i).minutes.ago) }

        open_account = create(:account)
        open_project = create(:project, account: open_account)
        open_run = create(:agent_run, :queued, project: open_project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(open_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "when the dispatch circuit breaker is half_open for an account" do
      it "allows a single probe run and blocks the rest until the interval elapses" do
        account = create(:account)
        project = create(:project, account: account)
        create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)
        blocked_run = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(probe_run.reload.temporal_workflow_id).to be_present
        expect(blocked_run.reload.status).to eq("queued")
      end

      it "stamps the dispatched probe run id on the breaker so only its outcome counts" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(breaker.reload.last_probe_run_id).to eq(probe_run.id)
      end

      it "does not stamp the probe when the workflow start fails" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "Connection refused")

        described_class.new.perform

        expect(probe_run.reload.status).to eq("failed")
        # The probe never actually dispatched, so the breaker must stay
        # probeable instead of blocking recovery for the probe interval.
        expect(breaker.reload.last_probe_run_id).to be_nil
        expect(breaker.reload.last_probe_at).to be_nil
      end

      it "does not stamp the probe when the claim is lost before dispatch" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        lost_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        # Another process wins the claim between peek and claim.
        allow(AgentRun).to receive(:claim_next_queued_run).and_return(nil)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(lost_run.reload.status).to eq("queued")
        expect(breaker.reload.last_probe_run_id).to be_nil
        expect(breaker.reload.last_probe_at).to be_nil
      end

      it "keeps the breaker probeable so the next run retries when a probe start fails" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        failed_probe = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
        retry_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
          raise StandardError, "Connection refused" if input[:agent_run_id] == failed_probe.id

          workflow_handle
        end

        described_class.new.perform

        expect(failed_probe.reload.status).to eq("failed")
        # The failed probe was not stamped, so the next run in the same pass
        # is treated as a fresh probe and the breaker records it on dispatch.
        expect(breaker.reload.last_probe_run_id).to eq(retry_run.id)
        expect(retry_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "with Capacity::Policy gating" do
      it "skips the Docker snapshot round trip for manual-only deployments" do
        # Resolving the deployment capacity policy requires a Docker system_info
        # + per-container stats round trip via current_capacity_policy. For
        # pure-manual deployments the legacy run-count gate already bounds
        # admission, so the policy must stay lazy and never invoke
        # DockerSnapshot.call or Capacity::Policy.call on a pass with no
        # auto-mode candidate.
        create_queued_run_with_policy(max_concurrent_runs: 5)

        expect(Capacity::DockerSnapshot).not_to receive(:call)
        expect(Capacity::Policy).not_to receive(:call)

        described_class.new.perform
      end

      it "dispatches under manual limits when auto mode is disabled by deployment policy" do
        # auto_allowed: false means "stay in manual mode", not "block all dispatch".
        # With headroom under the user's manual limit, the run should start.
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(remote_backend_decision)
        expect(Capacity::DockerSnapshot).not_to receive(:fetch)

        expect(temporal_client).to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.temporal_workflow_id).to be_present
      end

      it "blocks dispatch when the user is at manual capacity even if auto ceiling is higher" do
        # remote_backend_decision has effective_max_concurrent: 10, but auto_allowed
        # is false so only the user's manual limit (2) governs concurrency.
        project = create(:project)
        project.created_by.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: 2)
        create(:agent_run, :running, project: project)
        create(:agent_run, :running, project: project)
        queued_run = create(:agent_run, :queued, project: project)
        stub_policy_decision(remote_backend_decision)
        expect(Capacity::DockerSnapshot).not_to receive(:fetch)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "logs manual mode info when auto is disabled by deployment policy" do
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        # The policy downgrade is only meaningful (and only consulted) for an
        # auto-mode user; manual-only deployments skip the snapshot entirely.
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(missing_snapshot_decision)
        allow(Rails.logger).to receive(:info)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "process_run_queue.capacity_policy_manual_mode",
            mode: "manual"
          )
        )
      end

      it "forwards the CI signal to the capacity policy" do
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        # The policy is only consulted for auto-mode candidates, so the CI
        # signal only reaches Capacity::Policy when an auto-mode run is queued.
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        snapshot = ci_policy_snapshot
        allow(Capacity::DockerSnapshot).to receive(:call).and_return(snapshot)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CI").and_return("true")
        expect(Capacity::Policy).to receive(:call).with(snapshot: snapshot, ci: true).and_return(ci_policy_decision)
        expect(Capacity::DockerSnapshot).not_to receive(:fetch)
        expect(temporal_client).to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.temporal_workflow_id).to be_present
      end

      it "falls back to manual limits when the policy cannot be resolved" do
        project = create(:project)
        project.created_by.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: 1)
        queued_run = create(:agent_run, :queued, project: project)
        create(:agent_run, :running, project: project)

        # The policy is consulted because the owner is in auto mode. When
        # DockerSnapshot.call raises, ProcessRunQueueJob should log the
        # failure — surfacing the policy_unknown reason — and fall back to
        # the legacy tenant_max_concurrent_runs limit (fail-safe, not fail-loud).
        allow(Capacity::DockerSnapshot).to receive(:call).and_raise(StandardError, "docker unavailable")
        allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
          available: false, reason: "docker_unavailable", snapshot_at: Time.current, confidence: "low"
        )
        allow(Rails.logger).to receive(:warn)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "process_run_queue.capacity_policy_unavailable",
          reason: "policy_unknown"
        ))
      end

      it "keeps tenant max_concurrent_runs as a hard ceiling in auto mode" do
        project = create(:project)
        user = project.created_by
        user.settings.update!(run_concurrency_mode: "auto", max_concurrent_runs: 5)
        create(:tenant_setting, account: user.account, guardrails: { "max_concurrent_runs" => 3 })
        3.times { create(:agent_run, :running, project: project) }
        queued_run = create(:agent_run, :queued, project: project)
        stub_policy_decision(local_auto_decision)
        allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(
          available: true,
          effective_agent_budget_bytes: 16 * 1024 * 1024 * 1024,
          snapshot_at: Time.current,
          confidence: "high",
          docker_memory_bytes: 32 * 1024 * 1024 * 1024
        )

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "denies admission when Docker memory is exhausted even with run-count headroom" do
        # RDR-043: a healthy local user with max_concurrent_runs = 5 must not
        # dispatch when available_memory_bytes is 0, even though the count
        # limit still has room. The policy's docker_memory_exhausted reason
        # is a hard capacity block that must leave the run queued rather than
        # fall back to the legacy manual-count check.
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(capacity_blocked_decision)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "logs the capacity block reason when admission is denied" do
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(capacity_blocked_decision)
        allow(Rails.logger).to receive(:info)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "process_run_queue.capacity_blocked",
            reasons: include("docker_memory_exhausted")
          )
        )
      end

      it "logs Docker sampling timeout blocks as a host-safety capacity denial" do
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(sampling_budget_blocked_decision)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "process_run_queue.capacity_blocked",
            reasons: include("docker_sampling_budget_exceeded")
          )
        )
      end

      # @spec CONTAINER-RUNTIME-021
      it "parks provisioning-rate-limited runs until the admission window reopens" do
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        queued_run.project.created_by.settings.update!(run_concurrency_mode: "auto")
        stub_policy_decision(local_auto_decision)
        allow(Rails.logger).to receive(:info)
        available_at = Time.utc(2026, 8, 17, 12, 5, 0)
        allow(Capacity::DockerSnapshot).to receive(:fetch).and_return(auto_mode_snapshot)
        allow(Containers::BackendScheduler).to receive(:call).and_return(default_local_host_selection_result)
        allow(Capacity::RunAdmission).to receive(:call).and_return(
          provisioning_rate_denied_admission(available_at: available_at)
        )

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        queued_run.reload
        expect(queued_run.status).to eq("rate_limited")
        expect(queued_run.rate_limited_until).to eq(available_at)
        expect(queued_run.external_metadata["capacity_park_reason"]).to eq("global_provisioning_rate_limit")
      end
    end
  end

  def create_queued_run_with_policy(max_concurrent_runs:)
    project = create(:project)
    project.created_by.settings.update!(max_concurrent_runs: max_concurrent_runs)
    create(:agent_run, :queued, project: project)
  end

  def stub_policy_decision(decision)
    allow(Capacity::Policy).to receive(:call).and_return(decision)
  end

  def remote_backend_decision
    remote_snapshot = Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "remote",
      backend_kind: "remote",
      backend_shared: true,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 8_000_000_000,
      agent_container_count: 0,
      snapshot_at: Time.current,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )

    allow(Capacity::DockerSnapshot).to receive(:call).and_return(remote_snapshot)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_LINUX_DOCKER,
      auto_allowed: false,
      auto_allowed_reasons: [ "deployment_gate" ],
      blocked_reasons: [ Capacity::BlockedReason[:auto_mode_disabled_for_deployment] ],
      admission_uses_cpu: false,
      degraded: false,
      degraded_reasons: [],
      effective_max_concurrent: 10,
      snapshot_present: true
    )
  end

  def missing_snapshot_decision
    allow(Capacity::DockerSnapshot).to receive(:call).and_return(nil)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_UNKNOWN,
      auto_allowed: false,
      auto_allowed_reasons: [ "deployment_gate" ],
      blocked_reasons: [ Capacity::BlockedReason[:docker_unavailable] ],
      admission_uses_cpu: false,
      degraded: true,
      degraded_reasons: [ "no_snapshot" ],
      effective_max_concurrent: 4,
      snapshot_present: false
    )
  end

  def local_auto_decision
    local_snapshot = Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: Capacity::DockerSnapshot::EMPTY_BUCKETS,
      available_memory_bytes: 8_000_000_000,
      agent_container_count: 0,
      snapshot_at: Time.current,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )

    allow(Capacity::DockerSnapshot).to receive(:call).and_return(local_snapshot)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::AUTO,
      environment: Capacity::Policy::ENVIRONMENT_LINUX_DOCKER,
      auto_allowed: true,
      auto_allowed_reasons: [ "environment_default" ],
      blocked_reasons: [],
      admission_uses_cpu: false,
      degraded: false,
      degraded_reasons: [],
      effective_max_concurrent: 10,
      snapshot_present: true
    )
  end

  def capacity_blocked_decision
    exhausted_snapshot = Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: Capacity::DockerSnapshot::EMPTY_BUCKETS,
      available_memory_bytes: 0,
      agent_container_count: 5,
      snapshot_at: Time.current,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )

    allow(Capacity::DockerSnapshot).to receive(:call).and_return(exhausted_snapshot)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_LINUX_DOCKER,
      auto_allowed: false,
      auto_allowed_reasons: [ "docker_memory_exhausted" ],
      blocked_reasons: [ Capacity::BlockedReason[:docker_memory_exhausted] ],
      admission_uses_cpu: false,
      degraded: true,
      degraded_reasons: [ "docker_exhausted" ],
      effective_max_concurrent: 10,
      snapshot_present: true
    )
  end

  def sampling_budget_blocked_decision
    degraded_snapshot = Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: Capacity::DockerSnapshot::EMPTY_BUCKETS.merge(
        paid_agents: Capacity::DockerSnapshot::Bucket.new(container_count: 4, memory_bytes: 0, cpu_percent: 0.0)
      ),
      available_memory_bytes: 0,
      agent_container_count: 4,
      snapshot_at: Time.current,
      confidence: 0.1,
      degraded: true,
      degraded_reasons: [ "container_sampling_budget_exceeded" ]
    )

    allow(Capacity::DockerSnapshot).to receive(:call).and_return(degraded_snapshot)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_LINUX_DOCKER,
      auto_allowed: false,
      auto_allowed_reasons: [ "metrics_missing" ],
      blocked_reasons: [ Capacity::BlockedReason[:docker_sampling_budget_exceeded] ],
      admission_uses_cpu: false,
      degraded: true,
      degraded_reasons: [ "container_sampling_budget_exceeded" ],
      effective_max_concurrent: 10,
      snapshot_present: true
    )
  end

  def ci_policy_snapshot
    Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: Capacity::DockerSnapshot::EMPTY_BUCKETS,
      available_memory_bytes: 8_000_000_000,
      agent_container_count: 0,
      snapshot_at: Time.current,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )
  end

  def ci_policy_decision
    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_CI,
      auto_allowed: false,
      auto_allowed_reasons: [],
      blocked_reasons: [ Capacity::BlockedReason[:auto_mode_disabled_for_deployment] ],
      admission_uses_cpu: false,
      degraded: false,
      degraded_reasons: [],
      effective_max_concurrent: 2,
      snapshot_present: true
    )
  end

  describe "#temporal_priority_for" do # @spec QUEUE-TIER-001
    let(:project) { create(:project) }
    let(:expected_temporal_keys) do
      {
        manual: 1,
        pr_p1: 2,
        pr_p2: 2,
        pr_p3: 3,
        pr_continue: 3,
        issue_p1: 4,
        issue_p2: 4,
        issue_p3: 5,
        auto_pick: 5
      }
    end

    def issue_run(label: nil)
      issue = create(:issue, project: project, labels: Array(label))
      create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: issue)
    end

    def pr_run(github_number:, label: nil)
      create(:issue, project: project, is_pull_request: true, github_number: github_number, labels: Array(label))
      create(:agent_run, :queued, project: project, trigger_type: "automatic", source_pull_request_number: github_number)
    end

    def runs_by_tier
      {
        manual: create(:agent_run, :queued, project: project, trigger_type: "manual"),
        pr_p1: pr_run(github_number: 101, label: "P1"),
        pr_p2: pr_run(github_number: 102, label: "P2"),
        pr_p3: pr_run(github_number: 103, label: "P3"),
        pr_continue: pr_run(github_number: 104),
        issue_p1: issue_run(label: "P1"),
        issue_p2: issue_run(label: "P2"),
        issue_p3: issue_run(label: "P3"),
        auto_pick: issue_run
      }
    end

    it "compresses all queue tiers into the default Temporal 1..5 range" do
      actual_keys = runs_by_tier.transform_values { |run| temporal_priority_for(run).priority_key }

      expect(actual_keys).to eq(expected_temporal_keys)
    end
  end
end
