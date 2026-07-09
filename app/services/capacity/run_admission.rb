# frozen_string_literal: true

module Capacity
  class RunAdmission
    DEFAULT_ESTIMATED_MEMORY_BYTES = 4 * 1024 * 1024 * 1024

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(user:, project: nil, goal: nil, docker_snapshot: nil, reserved_agent_memory_bytes: nil, mode: nil)
      @user = user
      @project = project
      @goal = goal
      @docker_snapshot = docker_snapshot
      @reserved_agent_memory_bytes = reserved_agent_memory_bytes
      @mode = mode
    end

    def call
      return owner_missing_result unless user

      mode = @mode || user.settings.run_concurrency_mode
      return manual_result(mode: mode) unless mode == UserSetting::RUN_CONCURRENCY_MODE_AUTO

      auto_result
    end

    private

    attr_reader :docker_snapshot, :goal, :project, :reserved_agent_memory_bytes, :user

    def owner_missing_result
      {
        allowed: false,
        mode: nil,
        reason: "owner_not_found",
        user_active_count: nil,
        project_active_count: nil,
        create_pr_active_count: nil,
        effective_max_concurrent_runs: nil,
        available_slots: 0,
        available_memory_bytes: nil,
        estimated_memory_per_run_bytes: nil,
        reserved_agent_memory_bytes: nil,
        snapshot_available: false
      }
    end

    def manual_result(mode:)
      remaining_slots = [ user_available_slots, project_available_slots, create_pr_available_slots ].compact.min

      {
        allowed: remaining_slots.positive?,
        mode: mode,
        reason: denial_reason(remaining_memory_slots: nil),
        user_active_count: user_active_count,
        project_active_count: project_active_count,
        create_pr_active_count: create_pr_active_count,
        effective_max_concurrent_runs: user_hard_ceiling,
        available_slots: remaining_slots,
        available_memory_bytes: nil,
        estimated_memory_per_run_bytes: candidate_memory_bytes,
        reserved_agent_memory_bytes: nil,
        snapshot_available: false
      }
    end

    def auto_result
      snapshot = docker_snapshot || DockerSnapshot.fetch
      return degraded_manual_result(snapshot) unless snapshot[:available]

      estimated_memory_per_run_bytes = candidate_memory_bytes
      reserved_agent_memory_bytes = active_local_agent_reserved_bytes
      available_memory_bytes = [ snapshot[:effective_agent_budget_bytes].to_i - additional_local_agent_headroom_bytes(snapshot, reserved_agent_memory_bytes), 0 ].max
      remaining_memory_slots = available_memory_bytes / estimated_memory_per_run_bytes
      effective_max_concurrent_runs = [
        total_agent_budget_bytes(snapshot) / estimated_memory_per_run_bytes,
        user_hard_ceiling
      ].compact.min
      remaining_slots = [
        remaining_memory_slots,
        user_available_slots,
        project_available_slots,
        create_pr_available_slots
      ].compact.min

      decision = {
        allowed: remaining_slots.positive?,
        mode: UserSetting::RUN_CONCURRENCY_MODE_AUTO,
        reason: denial_reason(remaining_memory_slots: remaining_memory_slots),
        user_active_count: user_active_count,
        project_active_count: project_active_count,
        create_pr_active_count: create_pr_active_count,
        effective_max_concurrent_runs: effective_max_concurrent_runs,
        available_slots: remaining_slots,
        available_memory_bytes: available_memory_bytes,
        estimated_memory_per_run_bytes: estimated_memory_per_run_bytes,
        reserved_agent_memory_bytes: reserved_agent_memory_bytes,
        snapshot_available: true,
        snapshot_at: snapshot[:snapshot_at],
        docker_confidence: snapshot[:confidence],
        docker_memory_bytes: snapshot[:docker_memory_bytes]
      }

      # The capacity-blocked annotation only matters when Docker memory is
      # the binding constraint, so skip the Resolve lookup (which walks
      # project → account → global via find_by) entirely on allowed
      # admissions and on denials caused by the user/project/create_pr
      # ceilings, where the annotation could never explain the denial.
      annotate_capacity_blocked(decision) if decision[:reason] == "insufficient_docker_capacity"
      decision
    end

    def degraded_manual_result(snapshot)
      manual_result(mode: UserSetting::RUN_CONCURRENCY_MODE_AUTO).merge(
        degraded: true,
        docker_reason: snapshot[:reason],
        docker_error_class: snapshot[:error_class],
        docker_error_message: snapshot[:error_message],
        snapshot_available: false,
        snapshot_at: snapshot[:snapshot_at],
        docker_confidence: snapshot[:confidence]
      )
    end

    def denial_reason(remaining_memory_slots:)
      return nil if user_available_slots.positive? &&
        slot_available?(project_available_slots) &&
        slot_available?(create_pr_available_slots) &&
        (remaining_memory_slots.nil? || remaining_memory_slots.positive?)

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

    def project_available_slots
      return nil unless project

      @project_available_slots ||= [ user.settings.max_parallel_agents_per_project - project_active_count, 0 ].max
    end

    def create_pr_available_slots
      return nil unless goal == "create_pr"

      @create_pr_available_slots ||= [ user.account.tenant_max_concurrent_create_pr_runs - create_pr_active_count, 0 ].max
    end

    def user_hard_ceiling
      @user_hard_ceiling ||= user.account.tenant_max_concurrent_runs(user.settings.max_concurrent_runs) ||
        TenantSetting::DEFAULT_GUARDRAILS.fetch("max_concurrent_runs")
    end

    def candidate_memory_bytes
      user.settings.container_memory_bytes.presence || DEFAULT_ESTIMATED_MEMORY_BYTES
    end

    def total_agent_budget_bytes(snapshot)
      snapshot[:effective_agent_budget_bytes].to_i + snapshot[:agent_memory_bytes].to_i
    end

    def additional_local_agent_headroom_bytes(snapshot, reserved_agent_memory_bytes)
      [ reserved_agent_memory_bytes - snapshot[:agent_memory_bytes].to_i, 0 ].max
    end

    def active_local_agent_reserved_bytes
      return reserved_agent_memory_bytes unless reserved_agent_memory_bytes.nil?

      inflight_runs = AgentRun.capacity_inflight
        .where(container_host: [ nil, "", Containers::LOCAL_BACKEND_KEY.to_s ])
        .includes(project: [ :account, { created_by: :user_setting } ])
        .to_a

      latest_limits_by_run_id = latest_metric_limits_by_run_id(inflight_runs)

      inflight_runs.sum { |run| reserved_memory_bytes_for(run, latest_limits_by_run_id[run.id]) }
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
