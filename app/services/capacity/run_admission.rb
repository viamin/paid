# frozen_string_literal: true

module Capacity
  class RunAdmission
    DEFAULT_ESTIMATED_MEMORY_BYTES = 4 * 1024 * 1024 * 1024
    DOCKER_SAMPLING_TIMEOUT_REASON = "docker_sampling_budget_exceeded".freeze

    class << self
      def call(...)
        new(...).call
      end

      # Evaluates admission without recording infrastructure-spend side
      # effects (notifications, audit events, emergency control). Used by
      # capacity-aware host selection to compare several candidate hosts
      # before a final host is chosen — see
      # ProcessRunQueueJob#build_host_admission_evaluations and
      # #finalize_infrastructure_spend!, which re-checks the real guard once
      # against only the winning host.
      def preview(...)
        new(...).preview
      end
    end

    def initialize(user:, project: nil, goal: nil, agent_run: nil, docker_snapshot: nil, reserved_agent_memory_bytes: nil, mode: nil,
      selected_host: nil, selected_host_limit: nil, admission_snapshot: nil, now: Time.current)
      @user = user
      @project = project
      @goal = goal
      @agent_run = agent_run
      @docker_snapshot = docker_snapshot
      @reserved_agent_memory_bytes = reserved_agent_memory_bytes
      @mode = mode
      @selected_host = selected_host
      @selected_host_limit = selected_host_limit
      @admission_snapshot = admission_snapshot
      @now = now
    end

    def call
      build_decision(spend_guard_preview: false)
    end

    def preview
      build_decision(spend_guard_preview: true)
    end

    private

    attr_reader :admission_snapshot, :agent_run, :docker_snapshot, :goal, :now, :project, :reserved_agent_memory_bytes, :selected_host, :selected_host_limit, :user

    def build_decision(spend_guard_preview:)
      # @spec CONTAINER-RUNTIME-006
      return owner_missing_result unless user

      mode = @mode || user.settings.run_concurrency_mode
      decision = if mode == UserSetting::RUN_CONCURRENCY_MODE_AUTO
        auto_result
      else
        manual_result(mode: mode)
      end

      decorate_capacity_state(decision)
      apply_infrastructure_safety_rails(decision, spend_guard_preview: spend_guard_preview)
    end

    def owner_missing_result
      {
        allowed: false,
        mode: nil,
        reason: "owner_not_found",
        selected_host: selected_host,
        host_active_count: nil,
        host_max_concurrent_runs: selected_host_limit,
        host_available_slots: nil,
        user_active_count: nil,
        project_active_count: nil,
        create_pr_active_count: nil,
        global_active_count: nil,
        global_max_concurrent_executions: nil,
        global_available_slots: nil,
        effective_max_concurrent_runs: nil,
        available_slots: 0,
        available_memory_bytes: nil,
        estimated_memory_per_run_bytes: nil,
        reserved_agent_memory_bytes: nil,
        snapshot_available: false,
        rate_limited_until: nil
      }
    end

    def manual_result(mode:)
      remaining_slots = [ global_available_slots, host_available_slots, user_available_slots, project_available_slots, create_pr_available_slots ].compact.min

      {
        allowed: remaining_slots.positive?,
        mode: mode,
        reason: denial_reason(remaining_memory_slots: nil),
        selected_host: selected_host,
        host_active_count: host_active_count,
        host_max_concurrent_runs: selected_host_limit,
        host_available_slots: host_available_slots,
        user_active_count: user_active_count,
        project_active_count: project_active_count,
        create_pr_active_count: create_pr_active_count,
        global_active_count: global_active_count,
        global_max_concurrent_executions: global_limit,
        global_available_slots: global_available_slots,
        effective_max_concurrent_runs: user_hard_ceiling,
        available_slots: remaining_slots,
        available_memory_bytes: nil,
        estimated_memory_per_run_bytes: candidate_memory_bytes,
        reserved_agent_memory_bytes: nil,
        snapshot_available: false,
        rate_limited_until: nil
      }
    end

    def auto_result
      snapshot = docker_snapshot || DockerSnapshot.fetch(backend: selected_backend)
      return degraded_result(snapshot) unless snapshot[:available]

      estimated_memory_per_run_bytes = candidate_memory_bytes
      reserved_agent_memory_bytes = active_selected_host_agent_reserved_bytes
      available_memory_bytes = [
        snapshot[:effective_agent_budget_bytes].to_i - additional_selected_host_agent_headroom_bytes(snapshot, reserved_agent_memory_bytes), 0
      ].max
      remaining_memory_slots = available_memory_bytes / estimated_memory_per_run_bytes
      effective_max_concurrent_runs = [
        total_agent_budget_bytes(snapshot) / estimated_memory_per_run_bytes,
        user_hard_ceiling
      ].compact.min
      remaining_slots = [
        remaining_memory_slots,
        global_available_slots,
        host_available_slots,
        user_available_slots,
        project_available_slots,
        create_pr_available_slots
      ].compact.min

      decision = {
        allowed: remaining_slots.positive?,
        mode: UserSetting::RUN_CONCURRENCY_MODE_AUTO,
        reason: denial_reason(remaining_memory_slots: remaining_memory_slots),
        selected_host: selected_host,
        host_active_count: host_active_count,
        host_max_concurrent_runs: selected_host_limit,
        host_available_slots: host_available_slots,
        user_active_count: user_active_count,
        project_active_count: project_active_count,
        create_pr_active_count: create_pr_active_count,
        global_active_count: global_active_count,
        global_max_concurrent_executions: global_limit,
        global_available_slots: global_available_slots,
        effective_max_concurrent_runs: effective_max_concurrent_runs,
        available_slots: remaining_slots,
        available_memory_bytes: available_memory_bytes,
        estimated_memory_per_run_bytes: estimated_memory_per_run_bytes,
        reserved_agent_memory_bytes: reserved_agent_memory_bytes,
        snapshot_available: true,
        snapshot_at: snapshot[:snapshot_at],
        snapshot_backend_identifier: snapshot[:backend_identifier],
        docker_confidence: snapshot[:confidence],
        docker_memory_bytes: snapshot[:docker_memory_bytes],
        docker_degraded_reasons: snapshot[:degraded_reasons],
        rate_limited_until: nil
      }

      # The capacity-blocked annotation only matters when Docker memory is
      # the binding constraint, so skip the Resolve lookup (which walks
      # project → account → global via find_by) entirely on allowed
      # admissions and on denials caused by the user/project/create_pr
      # ceilings, where the annotation could never explain the denial.
      annotate_capacity_blocked(decision) if decision[:reason] == "insufficient_docker_capacity"
      decision
    end

    def degraded_result(snapshot)
      return degraded_sampling_timeout_result(snapshot) if snapshot[:reason] == "container_sampling_budget_exceeded"

      degraded_manual_result(snapshot)
    end

    def degraded_manual_result(snapshot)
      manual_result(mode: UserSetting::RUN_CONCURRENCY_MODE_AUTO).merge(
        degraded: true,
        docker_reason: snapshot[:reason],
        docker_degraded_reasons: snapshot[:degraded_reasons],
        docker_error_class: snapshot[:error_class],
        docker_error_message: snapshot[:error_message],
        snapshot_available: false,
        snapshot_at: snapshot[:snapshot_at],
        snapshot_backend_identifier: snapshot[:backend_identifier],
        docker_confidence: snapshot[:confidence]
      )
    end

    def degraded_sampling_timeout_result(snapshot)
      slot_reason = denial_reason(remaining_memory_slots: nil)
      reserved_memory_bytes = [
        active_selected_host_agent_reserved_bytes,
        snapshot[:agent_memory_bytes].to_i,
        snapshot[:agent_container_count].to_i * candidate_memory_bytes
      ].max

      {
        allowed: false,
        mode: UserSetting::RUN_CONCURRENCY_MODE_AUTO,
        reason: slot_reason || DOCKER_SAMPLING_TIMEOUT_REASON,
        selected_host: selected_host,
        host_active_count: host_active_count,
        host_max_concurrent_runs: selected_host_limit,
        host_available_slots: host_available_slots,
        user_active_count: user_active_count,
        project_active_count: project_active_count,
        create_pr_active_count: create_pr_active_count,
        global_active_count: global_active_count,
        global_max_concurrent_executions: global_limit,
        global_available_slots: global_available_slots,
        effective_max_concurrent_runs: user_hard_ceiling,
        available_slots: 0,
        available_memory_bytes: 0,
        estimated_memory_per_run_bytes: candidate_memory_bytes,
        reserved_agent_memory_bytes: reserved_memory_bytes,
        snapshot_available: false,
        snapshot_at: snapshot[:snapshot_at],
        snapshot_backend_identifier: snapshot[:backend_identifier],
        docker_confidence: snapshot[:confidence],
        docker_memory_bytes: snapshot[:docker_memory_bytes],
        docker_reason: snapshot[:reason],
        docker_degraded_reasons: snapshot[:degraded_reasons],
        docker_error_class: snapshot[:error_class],
        docker_error_message: snapshot[:error_message],
        docker_agent_container_count: snapshot[:agent_container_count].to_i,
        degraded: true,
        rate_limited_until: nil
      }
    end

    def decorate_capacity_state(decision)
      requested = requested_resources
      global_requested = global_requested_resources
      host_requested = host_requested_resources
      provisioning = provisioning_window

      decision.merge!(
        requested_cpu_quota: requested[:cpu_quota],
        requested_memory_bytes: requested[:memory_bytes],
        requested_disk_bytes: requested[:disk_bytes],
        current_global_requested_cpu_quota: global_requested[:cpu_quota],
        current_global_requested_memory_bytes: global_requested[:memory_bytes],
        current_global_requested_disk_bytes: global_requested[:disk_bytes],
        current_host_requested_cpu_quota: host_requested[:cpu_quota],
        current_host_requested_memory_bytes: host_requested[:memory_bytes],
        current_host_requested_disk_bytes: host_requested[:disk_bytes],
        global_requested_cpu_quota_limit: infrastructure_limits[:global_requested_cpu_quota_limit],
        host_requested_cpu_quota_limit: infrastructure_limits[:host_requested_cpu_quota_limit],
        global_requested_memory_bytes_limit: infrastructure_limits[:global_requested_memory_bytes_limit],
        host_requested_memory_bytes_limit: infrastructure_limits[:host_requested_memory_bytes_limit],
        global_requested_disk_bytes_limit: infrastructure_limits[:global_requested_disk_bytes_limit],
        host_requested_disk_bytes_limit: infrastructure_limits[:host_requested_disk_bytes_limit],
        max_execution_cpu_quota_limit: infrastructure_limits[:max_execution_cpu_quota_limit],
        max_execution_memory_bytes_limit: infrastructure_limits[:max_execution_memory_bytes_limit],
        max_execution_disk_bytes_limit: infrastructure_limits[:max_execution_disk_bytes_limit],
        current_global_provisionings_per_window: provisioning[:global_count],
        current_account_provisionings_per_window: provisioning[:account_count],
        current_project_provisionings_per_window: provisioning[:project_count],
        global_provisionings_per_window_limit: infrastructure_limits[:global_provisionings_per_window_limit],
        account_provisionings_per_window_limit: infrastructure_limits[:account_provisionings_per_window_limit],
        project_provisionings_per_window_limit: infrastructure_limits[:project_provisionings_per_window_limit]
      )
    end

    def apply_infrastructure_safety_rails(decision, spend_guard_preview:)
      return decision unless decision[:allowed]

      if (spend_denial = infrastructure_spend_denial(preview: spend_guard_preview))
        decision[:allowed] = false
        decision[:reason] = spend_denial[:reason]
        decision[:available_slots] = 0
        decision[:rate_limited_until] = spend_denial[:rate_limited_until]
        decision.merge!(spend_denial.except(:allowed, :reason, :rate_limited_until))
        return decision
      end

      reason, rate_limited_until = infrastructure_denial
      return decision unless reason

      decision[:allowed] = false
      decision[:reason] = reason
      decision[:available_slots] = 0
      decision[:rate_limited_until] = rate_limited_until
      decision
    end

    def infrastructure_spend_denial(preview:)
      guard_method = preview ? :preview : :call
      result = Capacity::InfrastructureSpendGuard.public_send(
        guard_method,
        account: user.account,
        project: project,
        agent_run: agent_run,
        selected_host: selected_host,
        now: now
      )

      result unless result[:allowed]
    end

    def infrastructure_denial
      execution_resource_denial ||
        aggregate_requested_resource_denial ||
        provisioning_rate_denial
    end

    def execution_resource_denial
      return [ "execution_cpu_limit_exceeded", nil ] if requested_resources[:cpu_quota] > infrastructure_limits[:max_execution_cpu_quota_limit].to_i
      return [ "execution_memory_limit_exceeded", nil ] if requested_resources[:memory_bytes] > infrastructure_limits[:max_execution_memory_bytes_limit].to_i
      return [ "execution_disk_limit_exceeded", nil ] if requested_resources[:disk_bytes] > infrastructure_limits[:max_execution_disk_bytes_limit].to_i

      nil
    end

    def aggregate_requested_resource_denial
      checks = [
        [ "global_requested_cpu_ceiling", current_global_requested_cpu_quota, infrastructure_limits[:global_requested_cpu_quota_limit], requested_resources[:cpu_quota] ],
        [ "global_requested_memory_ceiling", current_global_requested_memory_bytes, infrastructure_limits[:global_requested_memory_bytes_limit], requested_resources[:memory_bytes] ],
        [ "global_requested_disk_ceiling", current_global_requested_disk_bytes, infrastructure_limits[:global_requested_disk_bytes_limit], requested_resources[:disk_bytes] ],
        [ "host_requested_cpu_ceiling", current_host_requested_cpu_quota, infrastructure_limits[:host_requested_cpu_quota_limit], requested_resources[:cpu_quota] ],
        [ "host_requested_memory_ceiling", current_host_requested_memory_bytes, infrastructure_limits[:host_requested_memory_bytes_limit], requested_resources[:memory_bytes] ],
        [ "host_requested_disk_ceiling", current_host_requested_disk_bytes, infrastructure_limits[:host_requested_disk_bytes_limit], requested_resources[:disk_bytes] ]
      ]

      checks.each do |reason, current, limit, requested|
        next if limit.to_i <= 0
        return [ reason, nil ] if current + requested > limit.to_i
      end

      nil
    end

    def provisioning_rate_denial
      limit = infrastructure_limits[:global_provisionings_per_window_limit].to_i
      return [ "global_provisioning_rate_limit", provisioning_window[:next_available_at] ] if limit.positive? && provisioning_window[:global_count] >= limit

      limit = infrastructure_limits[:account_provisionings_per_window_limit].to_i
      if limit.positive? && provisioning_window[:account_count] >= limit
        return [ "account_provisioning_rate_limit", provisioning_window[:account_next_available_at] ]
      end

      limit = infrastructure_limits[:project_provisionings_per_window_limit].to_i
      if limit.positive? && provisioning_window[:project_count] >= limit
        return [ "project_provisioning_rate_limit", provisioning_window[:project_next_available_at] ]
      end

      nil
    end

    def denial_reason(remaining_memory_slots:)
      return nil if user_available_slots.positive? &&
        slot_available?(host_available_slots) &&
        slot_available?(project_available_slots) &&
        slot_available?(create_pr_available_slots) &&
        slot_available?(global_available_slots) &&
        (remaining_memory_slots.nil? || remaining_memory_slots.positive?)

      return "global_hard_ceiling" if global_available_slots.present? && global_available_slots <= 0
      return "host_hard_ceiling" if selected_host_limit && host_available_slots.to_i <= 0
      return "insufficient_docker_capacity" if !remaining_memory_slots.nil? && remaining_memory_slots <= 0
      return "user_hard_ceiling" if user_available_slots <= 0
      return "project_hard_ceiling" if project && project_available_slots <= 0
      return "create_pr_hard_ceiling" if goal == "create_pr" && create_pr_available_slots.to_i <= 0

      "capacity_denied"
    end

    # Surfaces the capacity-blocked signal on admission decisions so callers
    # and operators can distinguish "no Docker memory" from "no Docker memory
    # because the workload keeps OOMing at the configured ceiling".
    #
    # RunAdmission runs at admission time, before the runner_key for the
    # next run has been selected, so the lookup intentionally passes
    # `runner_key: nil`. That skips the `specific` and `runner_goal`
    # scopes in `Resolve` and only surfaces `project`, `account`, and
    # `global` profiles that have hit their ceiling — broad enough to
    # explain the denial to operators without locking in on a runner
    # that may not be picked.
    def annotate_capacity_blocked(decision)
      profile = capacity_blocked_profile
      return unless profile

      decision[:capacity_blocked] = true
      decision[:capacity_blocked_profile_level] = profile.profile_level
      decision[:capacity_blocked_at] = profile.capacity_blocked_at
      decision[:capacity_blocked_oom_count] = profile.oom_count
      decision[:capacity_blocked_recommended_limit_bytes] = profile.recommended_memory_limit_bytes
    end

    def capacity_blocked_profile
      return @capacity_blocked_profile if defined?(@capacity_blocked_profile)

      profile = AgentRunResourceProfiles::Resolve.call(
        project: project,
        runner_key: nil,
        goal: goal
      )[:profile]
      @capacity_blocked_profile = profile&.capacity_blocked? ? profile : nil
    end

    def slot_available?(slots)
      slots.nil? || slots.positive?
    end

    def user_active_count
      @user_active_count ||= AgentRun.active_count_for_user(user)
    end

    def project_active_count
      @project_active_count ||= project ? AgentRun.active_count_for_project(project) : nil
    end

    def create_pr_active_count
      @create_pr_active_count ||= goal == "create_pr" ? AgentRun.active_create_pr_count_for_account(user.account) : nil
    end

    def user_available_slots
      @user_available_slots ||= [ user_hard_ceiling - user_active_count, 0 ].max
    end

    def host_active_count
      return nil unless selected_host_limit

      @host_active_count ||= AgentRun.active_count_for_host(selected_host)
    end

    def host_available_slots
      return nil unless selected_host_limit

      @host_available_slots ||= [ selected_host_limit - host_active_count, 0 ].max
    end

    def project_available_slots
      return nil unless project

      @project_available_slots ||= [ user.settings.max_parallel_agents_per_project - project_active_count, 0 ].max
    end

    def create_pr_available_slots
      return nil unless goal == "create_pr"

      @create_pr_available_slots ||= [ user.account.tenant_max_concurrent_create_pr_runs - create_pr_active_count, 0 ].max
    end

    def global_active_count
      @global_active_count ||= AgentRun.active_count_global
    end

    def global_limit
      @global_limit ||= Capacity::GlobalLimit.max_concurrent_executions
    end

    def global_available_slots
      return @global_available_slots if defined?(@global_available_slots)

      # A limit of 0 disables the global ceiling (consistent with the
      # per-host "0 means unlimited" convention and GlobalLimit.enabled?).
      # Returning nil lets slot_available? and the compact.min reductions
      # treat the global dimension as non-binding.
      @global_available_slots = Capacity::GlobalLimit.enabled? ? [ global_limit - global_active_count, 0 ].max : nil
    end

    def user_hard_ceiling
      @user_hard_ceiling ||= user.account.tenant_max_concurrent_runs(user.settings.max_concurrent_runs) ||
        TenantSetting::DEFAULT_GUARDRAILS.fetch("max_concurrent_runs")
    end

    def candidate_memory_bytes
      user.settings.container_memory_bytes.presence || DEFAULT_ESTIMATED_MEMORY_BYTES
    end

    def requested_resources
      @requested_resources ||= Capacity::RequestedResources.for_context(
        user: user,
        project: project,
        external_metadata: agent_run&.external_metadata
      )
    end

    def global_requested_resources
      @global_requested_resources ||= if admission_snapshot
        admission_snapshot.global_requested_resources
      else
        TenantContext.with_system_access do
          Capacity::RequestedResources.sum_for(AgentRun.capacity_inflight)
        end
      end
    end

    def host_requested_resources
      @host_requested_resources ||= if selected_host.blank?
        Capacity::RequestedResources.zero
      elsif admission_snapshot
        admission_snapshot.host_requested_resources(selected_host)
      else
        # A host is a shared physical resource spanning all tenants, and
        # agent_runs has FORCE ROW LEVEL SECURITY, so the aggregate must be
        # loaded inside the bypass block. Building the relation inside and
        # summing after the block exits would let the lazy load run RLS-scoped
        # to the calling tenant and undercount the host. See
        # AgentRun.active_count_for_host for the same concern.
        TenantContext.with_system_access do
          Capacity::RequestedResources.sum_for(AgentRun.capacity_inflight_for_host(selected_host))
        end
      end
    end

    def current_global_requested_cpu_quota = global_requested_resources[:cpu_quota]
    def current_global_requested_memory_bytes = global_requested_resources[:memory_bytes]
    def current_global_requested_disk_bytes = global_requested_resources[:disk_bytes]
    def current_host_requested_cpu_quota = host_requested_resources[:cpu_quota]
    def current_host_requested_memory_bytes = host_requested_resources[:memory_bytes]
    def current_host_requested_disk_bytes = host_requested_resources[:disk_bytes]

    def infrastructure_limits
      @infrastructure_limits ||= Capacity::InfrastructureLimits.current(host: selected_host)
    end

    def provisioning_window
      @provisioning_window ||= if admission_snapshot
        admission_snapshot.provisioning_window(account: user.account, project: project)
      else
        Capacity::ProvisioningRateWindow.call(
          account: user.account,
          project: project,
          window_seconds: infrastructure_limits[:provisioning_rate_window_seconds],
          now: now
        )
      end
    end

    def total_agent_budget_bytes(snapshot)
      snapshot[:effective_agent_budget_bytes].to_i + snapshot[:agent_memory_bytes].to_i
    end

    def additional_selected_host_agent_headroom_bytes(snapshot, reserved_agent_memory_bytes)
      [ reserved_agent_memory_bytes - snapshot[:agent_memory_bytes].to_i, 0 ].max
    end

    def active_selected_host_agent_reserved_bytes
      return reserved_agent_memory_bytes unless reserved_agent_memory_bytes.nil?

      inflight_runs = AgentRun.capacity_inflight
        .where(
          "COALESCE(NULLIF(container_host, ''), COALESCE(external_metadata->>'planned_container_host', '')) IN (:scope)",
          scope: selected_host_scope
        )
        .includes(project: [ :account, { created_by: :user_setting } ])
        .to_a

      latest_limits_by_run_id = latest_metric_limits_by_run_id(inflight_runs)

      inflight_runs.sum { |run| reserved_memory_bytes_for(run, latest_limits_by_run_id[run.id]) }
    end

    def selected_backend
      @selected_backend ||= Containers.backend_for(selected_host)
    end

    def selected_host_scope
      @selected_host_scope ||= begin
        identifiers = selected_backend.all_host_identifiers.map(&:to_s)
        selected_backend.remote? ? identifiers : identifiers + [ "" ]
      end
    rescue Containers::Backends::Resolver::UnknownBackendError
      [ selected_host.to_s ]
    end

    def latest_metric_limits_by_run_id(inflight_runs)
      return {} if inflight_runs.empty?

      ContainerMetric
        .where(agent_run_id: inflight_runs.map(&:id))
        .select("DISTINCT ON (agent_run_id) agent_run_id, memory_limit_bytes")
        .order(:agent_run_id, recorded_at: :desc, id: :desc)
        .pluck(:agent_run_id, :memory_limit_bytes)
        .to_h
    end

    def reserved_memory_bytes_for(run, latest_limit)
      configured_limit = run.project&.effective_owner&.settings&.container_memory_bytes.to_i
      [ latest_limit.to_i, configured_limit, run.peak_memory_bytes.to_i, DEFAULT_ESTIMATED_MEMORY_BYTES ].max
    end
  end
end
