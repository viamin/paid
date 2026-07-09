# frozen_string_literal: true

module AgentRunResourceProfiles
  class RefreshForRun
    LOOKBACK_WINDOW = 90.days

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return unless refreshable?

      profile_definitions.each do |definition|
        refresh_profile(definition)
      end
    end

    private

    attr_reader :agent_run

    def refreshable?
      agent_run.finished? && agent_run.project.present? && agent_run.resource_profile_runner_key.present?
    end

    def profile_definitions
      [
        {
          profile_level: "specific",
          account_id: account_id,
          project_id: agent_run.project_id,
          runner_key: runner_key,
          goal: goal
        },
        {
          profile_level: "runner_goal",
          runner_key: runner_key,
          goal: goal
        },
        {
          profile_level: "project",
          account_id: account_id,
          project_id: agent_run.project_id
        },
        {
          profile_level: "account",
          account_id: account_id
        },
        {
          profile_level: "global"
        }
      ]
    end

    def refresh_profile(definition)
      summary = summarize_samples(definition)
      return unless summary

      profile = AgentRunResourceProfile.find_or_initialize_by(
        lookup_key: lookup_key_for(definition)
      )

      prior_limit = profile.recommended_memory_limit_bytes
      prior_capacity_blocked = profile.capacity_blocked?
      tuning_decision = MemoryLimitTuner.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: summary[:recommended_memory_limit_bytes],
        p95_memory_bytes: summary[:p95_memory_bytes],
        projected_oom_count: summary[:oom_count]
      ).call

      summary[:recommended_memory_limit_bytes] = tuning_decision.recommended_limit_bytes
      summary[:capacity_blocked] = tuning_decision.capacity_blocked?
      summary[:capacity_blocked_at] = tuning_decision.capacity_blocked_at
      summary[:consecutive_low_memory_samples] = tuning_decision.consecutive_low_memory_samples
      summary[:downward_tuning_count] = tuning_decision.downward_tuning_count

      profile.assign_attributes(definition.merge(summary))
      profile.save!

      log_tuning_change(profile, prior_limit, prior_capacity_blocked, tuning_decision)
    end

    def summarize_samples(definition)
      runs = source_runs_for(definition)
      samples = runs.filter_map { |run| sample_for(run, metric_limit_for(run.id)) }
      return if samples.empty?

      sorted_memory = samples.map { |sample| sample[:memory_bytes] }.sort
      oom_samples = samples.select { |sample| sample[:oom] }

      {
        sample_count: samples.size,
        p50_memory_bytes: percentile(sorted_memory, 0.5),
        p95_memory_bytes: percentile(sorted_memory, 0.95),
        max_memory_bytes: sorted_memory.max,
        oom_count: oom_samples.size,
        last_oom_at: oom_samples.map { |sample| sample[:completed_at] }.compact.max,
        recommended_memory_limit_bytes: baseline_memory_limit_bytes(
          p95_memory_bytes: percentile(sorted_memory, 0.95),
          max_memory_bytes: sorted_memory.max,
          oom_bump_basis_bytes: oom_bump_basis_bytes(oom_samples)
        )
      }
    end

    # The OOM headroom bump must fire for any OOM-killed run, per the RDR. When
    # the actual memory limit is known it is the most accurate basis for the
    # bump; a run with no ContainerMetric row (or one with a non-positive limit)
    # falls back to the observed peak, which is a conservative proxy because the
    # container was killed at or below its real (unknown) limit.
    def oom_bump_basis_bytes(oom_samples)
      oom_samples.filter_map do |sample|
        limit = sample[:memory_limit_bytes]
        limit.positive? ? limit : sample[:memory_bytes]
      end.max
    end

    def source_runs_for(definition)
      base = base_scope_for(definition)
      runner_key_filter = definition[:runner_key]
      base = base.where(runner_key_filter_clause(runner_key_filter)) if runner_key_filter

      base.to_a
    end

    def base_scope_for(definition)
      case definition.fetch(:profile_level)
      when "specific"
        scoped_runs.where(project_id: definition.fetch(:project_id), goal: definition.fetch(:goal))
      when "runner_goal"
        finished_runs.where(goal: definition.fetch(:goal))
      when "project"
        scoped_runs.where(project_id: definition.fetch(:project_id))
      when "account"
        scoped_runs
      when "global"
        finished_runs
      else
        AgentRun.none
      end
    end

    # Builds a SQL equality predicate against AgentRun.effective_runner_sql so
    # the runner_key filter is applied in SQL instead of hydrating every row
    # in scope and filtering in Ruby. effective_runner_sql is sourced from a
    # whitelist (AgentRun::NORMALIZABLE_COLUMNS), so wrapping the value via
    # `eq` keeps it as a bound parameter.
    def runner_key_filter_clause(runner_key)
      Arel.sql(AgentRun.effective_runner_sql).eq(runner_key)
    end

    def metric_limit_for(run_id)
      metric_limits_by_run_id[run_id].to_i
    end

    # Precomputes ContainerMetric#memory_limit_bytes for every finished run in
    # the lookback window once per refresh, instead of issuing one query per
    # profile level. The per-level base_scope_for relations are nested
    # supersets of the same finished_runs set, so this avoids 4 redundant
    # ContainerMetric lookups per refresh.
    def metric_limits_by_run_id
      @metric_limits_by_run_id ||= ContainerMetric
        .where(agent_run_id: finished_runs.select(:id))
        .group(:agent_run_id)
        .maximum(:memory_limit_bytes)
    end

    def sample_for(run, metric_limit_bytes)
      memory_bytes = sampled_memory_bytes_for(run, metric_limit_bytes)
      return if memory_bytes <= 0

      {
        memory_bytes: memory_bytes,
        memory_limit_bytes: metric_limit_bytes,
        oom: run.resource_profile_oom?,
        completed_at: run.completed_at
      }
    end

    def sampled_memory_bytes_for(run, metric_limit_bytes)
      peak = run.peak_memory_bytes.to_i
      limit = metric_limit_bytes.to_i

      if run.resource_profile_oom? && limit.positive?
        [ peak, limit ].max
      else
        peak
      end
    end

    def percentile(sorted_values, quantile)
      return 0 if sorted_values.empty?

      rank = quantile * (sorted_values.length - 1)
      lower = rank.floor
      upper = rank.ceil
      return sorted_values[lower] if lower == upper

      lower_value = sorted_values[lower]
      upper_value = sorted_values[upper]

      (lower_value + ((upper_value - lower_value) * (rank - lower))).round
    end

    # The "raw" recommended limit before the auto-tuning policy in
    # MemoryLimitTuner adjusts for ceiling/floor and capacity-blocked state.
    def baseline_memory_limit_bytes(p95_memory_bytes:, max_memory_bytes:, oom_bump_basis_bytes:)
      baseline = [
        AgentRunResourceProfile::MIN_RECOMMENDED_MEMORY_LIMIT_BYTES,
        (p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil,
        max_memory_bytes.to_i
      ].max

      if oom_bump_basis_bytes.to_i.positive?
        baseline = [
          baseline,
          (oom_bump_basis_bytes * AgentRunResourceProfile::OOM_BUMP_MULTIPLIER).ceil
        ].max
      end

      [ baseline, UserSetting::MAX_CONTAINER_MEMORY_BYTES ].min
    end

    def lookup_key_for(definition)
      AgentRunResourceProfile.lookup_key_for(**definition)
    end

    def finished_runs
      AgentRun.where(status: AgentRun::FINISHED_STATUSES, completed_at: LOOKBACK_WINDOW.ago..)
    end

    def scoped_runs
      finished_runs.joins(:project).where(projects: { account_id: account_id })
    end

    def account_id
      @account_id ||= agent_run.project.account_id
    end

    def goal
      @goal ||= agent_run.goal
    end

    def runner_key
      @runner_key ||= agent_run.resource_profile_runner_key
    end

    def user_settings
      @user_settings ||= begin
        owner = agent_run.project&.effective_owner
        owner&.user_setting
      end
    end

    def log_tuning_change(profile, prior_limit, prior_capacity_blocked, decision)
      return if prior_limit.to_i == decision.recommended_limit_bytes && prior_capacity_blocked == decision.capacity_blocked?

      payload = {
        message: "agent_run_resource_profile.memory_limit_tuned",
        profile_level: profile.profile_level,
        lookup_key: profile.lookup_key,
        prior_limit_bytes: prior_limit.to_i,
        new_limit_bytes: decision.recommended_limit_bytes,
        ceiling_bytes: decision.ceiling_bytes,
        floor_bytes: decision.floor_bytes,
        capacity_blocked: decision.capacity_blocked?,
        capacity_blocked_at: decision.capacity_blocked_at&.iso8601,
        downward_tuned: decision.downward_tuned?,
        consecutive_low_memory_samples: decision.consecutive_low_memory_samples,
        downward_tuning_count: decision.downward_tuning_count,
        oom_count: profile.oom_count
      }
      Rails.logger.info(payload)
    end
  end
end
