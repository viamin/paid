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

      profile.assign_attributes(definition.merge(summary))
      profile.save!
    end

    def summarize_samples(definition)
      runs = source_runs_for(definition)
      metric_limits = metric_limits_for(runs.map(&:id))
      samples = runs.filter_map { |run| sample_for(run, metric_limits[run.id].to_i) }
      return if samples.empty?

      sorted_memory = samples.map { |sample| sample[:memory_bytes] }.sort
      oom_samples = samples.select { |sample| sample[:oom] }
      oom_limits = oom_samples.filter_map { |sample| sample[:memory_limit_bytes] }.select(&:positive?)

      {
        sample_count: samples.size,
        p50_memory_bytes: percentile(sorted_memory, 0.5),
        p95_memory_bytes: percentile(sorted_memory, 0.95),
        max_memory_bytes: sorted_memory.max,
        oom_count: oom_samples.size,
        last_oom_at: oom_samples.map { |sample| sample[:completed_at] }.compact.max,
        recommended_memory_limit_bytes: recommended_memory_limit_bytes(
          p95_memory_bytes: percentile(sorted_memory, 0.95),
          max_memory_bytes: sorted_memory.max,
          oom_memory_limit_bytes: oom_limits.max
        )
      }
    end

    def source_runs_for(definition)
      case definition.fetch(:profile_level)
      when "specific"
        scoped_runs.where(project_id: definition.fetch(:project_id), goal: definition.fetch(:goal))
          .to_a
          .select { |run| run.resource_profile_runner_key == definition.fetch(:runner_key) }
      when "runner_goal"
        finished_runs.where(goal: definition.fetch(:goal))
          .to_a
          .select { |run| run.resource_profile_runner_key == definition.fetch(:runner_key) }
      when "project"
        scoped_runs.where(project_id: definition.fetch(:project_id)).to_a
      when "account"
        scoped_runs.to_a
      when "global"
        finished_runs.to_a
      else
        []
      end
    end

    def metric_limits_for(run_ids)
      return {} if run_ids.empty?

      ContainerMetric.where(agent_run_id: run_ids).group(:agent_run_id).maximum(:memory_limit_bytes)
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

    def recommended_memory_limit_bytes(p95_memory_bytes:, max_memory_bytes:, oom_memory_limit_bytes:)
      baseline = [
        AgentRunResourceProfile::MIN_RECOMMENDED_MEMORY_LIMIT_BYTES,
        (p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil,
        max_memory_bytes.to_i
      ].max

      if oom_memory_limit_bytes.to_i.positive?
        baseline = [
          baseline,
          (oom_memory_limit_bytes * AgentRunResourceProfile::OOM_BUMP_MULTIPLIER).ceil
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
  end
end
