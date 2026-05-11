# frozen_string_literal: true

module AgentRunPatterns
  class Detect
    FAILURE_STREAK_THRESHOLD = 3
    HIGH_FAILURE_RATE_THRESHOLD = 0.8
    HIGH_FAILURE_MIN_SAMPLE = 5
    ERROR_CLUSTER_MIN_SIZE = 3
    DEFAULT_WINDOW_HOURS = 6
    BASELINE_WINDOW_DAYS = 30
    DETECTION_FINISHED_STATUSES = (AgentRun::FINISHED_STATUSES - [ "retried" ]).freeze

    Pattern = Data.define(:type, :goal, :severity, :details)

    def self.call(...)
      new(...).call
    end

    def initialize(account:, window_hours: DEFAULT_WINDOW_HOURS)
      @account = account
      @window_hours = window_hours
    end

    def call
      runs = fetch_recent_finished_runs
      return [] if runs.empty?

      grouped = runs.group_by(&:goal)
      patterns = []

      grouped.each do |goal, goal_runs|
        patterns.concat(detect_failure_streak(goal, goal_runs))
        patterns.concat(detect_high_failure_rate(goal, goal_runs))
        patterns.concat(detect_error_clusters(goal, goal_runs))
      end

      deduplicate_patterns(patterns)
    end

    private

    attr_reader :account, :window_hours

    def fetch_recent_finished_runs
      AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where(status: DETECTION_FINISHED_STATUSES)
        .where(completed_at: window_hours.hours.ago..)
        .order(completed_at: :desc)
    end

    def detect_failure_streak(goal, runs)
      ordered = runs.sort_by { |r| -r.completed_at.to_i }
      streak = ordered.take_while { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }

      return [] unless streak.size >= FAILURE_STREAK_THRESHOLD

      [ Pattern.new(
        type: :failure_streak,
        goal: goal,
        severity: :error,
        details: {
          streak_length: streak.size,
          total_runs: runs.size,
          failure_rate: streak.size.to_f / runs.size,
          error_messages: streak.filter_map(&:error_message).first(5),
          run_ids: streak.map(&:id),
          started_at: streak.last.completed_at,
          ended_at: streak.first.completed_at
        }
      ) ]
    end

    def detect_high_failure_rate(goal, runs)
      failed = runs.count { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
      failure_rate = failed.to_f / runs.size

      return [] unless runs.size >= HIGH_FAILURE_MIN_SAMPLE
      return [] unless failure_rate >= HIGH_FAILURE_RATE_THRESHOLD

      baseline = load_baseline_rate(goal)
      severity = elevated_vs_baseline?(failure_rate, baseline) ? :error : :warning

      [ Pattern.new(
        type: :high_failure_rate,
        goal: goal,
        severity: severity,
        details: {
          failure_count: failed,
          total_count: runs.size,
          failure_rate: failure_rate.round(4),
          baseline_rate: baseline&.round(4),
          error_messages: runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
                              .filter_map(&:error_message).first(5),
          run_ids: runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }.map(&:id)
        }
      ) ]
    end

    def detect_error_clusters(goal, runs)
      failed_runs = runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
      return [] if failed_runs.empty?

      by_normalized_error = failed_runs
        .select { |r| r.error_message.present? }
        .group_by { |r| normalize_error(r.error_message) }

      clusters = []
      by_normalized_error.each do |normalized_msg, error_runs|
        next unless error_runs.size >= ERROR_CLUSTER_MIN_SIZE

        clusters << Pattern.new(
          type: :error_cluster,
          goal: goal,
          severity: :error,
          details: {
            error_pattern: normalized_msg,
            occurrence_count: error_runs.size,
            total_failures: failed_runs.size,
            sample_messages: error_runs.map(&:error_message).compact.uniq.first(3),
            run_ids: error_runs.map(&:id),
            statuses: error_runs.group_by(&:status).transform_values(&:count)
          }
        )
      end

      clusters
    end

    def normalize_error(message)
      message
        .gsub(%r{https?://\S+}, "<URL>")
        .gsub(/\/[\w\/]+/, "<PATH>")
        .gsub(/\b(?:[0-9a-f]{8,}|(?=[A-Za-z0-9_-]{8,}\b)(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+)\b/i, "<ID>")
        .gsub(/\b\d+(?:\.\d+)?[a-z]*\b/i, "<N>")
        .truncate(200)
    end

    def load_baseline_rate(goal)
      window_start = BASELINE_WINDOW_DAYS.days.ago
      recent_start = window_hours.hours.ago

      counts = AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where(goal: goal, status: DETECTION_FINISHED_STATUSES)
        .where(completed_at: window_start...recent_start)
        .group(:status)
        .count

      total = counts.values.sum

      return nil if total < HIGH_FAILURE_MIN_SAMPLE

      failed = counts.slice(*AgentRun::FAILURE_STATUSES).values.sum

      failed.to_f / total
    end

    def elevated_vs_baseline?(current_rate, baseline_rate)
      return true if baseline_rate.nil?
      return true if baseline_rate < 0.1 && current_rate > 0.5

      current_rate > baseline_rate * 2
    end

    def deduplicate_patterns(patterns)
      seen = Set.new
      patterns.select do |pattern|
        key = [ pattern.type, pattern.goal, deduplication_suffix(pattern) ]
        next false if seen.include?(key)

        seen.add(key)
        true
      end
    end

    def deduplication_suffix(pattern)
      return pattern.details[:error_pattern] if pattern.type == :error_cluster

      nil
    end
  end
end
