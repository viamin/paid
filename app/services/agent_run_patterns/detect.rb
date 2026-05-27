# frozen_string_literal: true

module AgentRunPatterns
  class Detect
    FAILURE_STREAK_THRESHOLD = 3
    HIGH_FAILURE_RATE_THRESHOLD = 0.8
    HIGH_FAILURE_MIN_SAMPLE = 5
    ERROR_CLUSTER_MIN_SIZE = 3
    DEFAULT_WINDOW_HOURS = 6
    BASELINE_WINDOW_DAYS = 30
    EVIDENCE_LOG_TAIL_LINE_LIMIT = 20
    EVIDENCE_MESSAGE_LIMIT = 5
    EVIDENCE_RUNNER_ATTEMPT_LIMIT = 10
    EVIDENCE_RUNNER_CONFIG_LIMIT = 5
    EVIDENCE_SAFE_RUNNER_CONFIG_FIELDS = %w[runner_key auth_type tier_model_ids].freeze
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

      sort_patterns(deduplicate_patterns(patterns))
    end

    private

    attr_reader :account, :window_hours

    def fetch_recent_finished_runs
      AgentRun.includes(:runner)
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(status: DETECTION_FINISHED_STATUSES)
        .where(completed_at: window_hours.hours.ago..)
        .order(completed_at: :desc)
    end

    def detect_failure_streak(goal, runs)
      ordered = runs.sort_by { |r| [ -r.completed_at.to_f, -r.id.to_i ] }
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
          evidence_bundle: build_evidence_bundle(streak),
          run_ids: streak.map(&:id),
          started_at: streak.last.completed_at,
          ended_at: streak.first.completed_at
        }
      ) ]
    end

    def detect_high_failure_rate(goal, runs)
      failed_runs = runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
      failed = failed_runs.size
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
          error_messages: failed_runs.filter_map(&:error_message).first(5),
          evidence_bundle: build_evidence_bundle(failed_runs),
          run_ids: failed_runs.map(&:id)
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
            evidence_bundle: build_evidence_bundle(error_runs),
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

    def build_evidence_bundle(runs)
      EvidenceBundle.new(
        outer_errors: sanitize_strings(runs.filter_map { |run| run.try(:error_message) }.uniq.first(EVIDENCE_MESSAGE_LIMIT)),
        runner_attempts: runner_attempt_evidence(runs),
        log_tails: log_tail_evidence(runs),
        runner_configs: runner_config_evidence(runs),
        aggregate_stats: aggregate_stats_for(runs)
      ).to_payload
    end

    def runner_attempt_evidence(runs)
      Array(runs).flat_map do |run|
        Array(read_attribute(run, :runners_attempted)).filter_map do |attempt|
          build_attempt_evidence(attempt)
        end
      end.first(EVIDENCE_RUNNER_ATTEMPT_LIMIT)
    end

    def build_attempt_evidence(attempt)
      value = attempt.to_h.deep_symbolize_keys
      evidence = {
        runner: sanitize_text(value[:runner]),
        error_type: sanitize_text(value[:error_type]),
        error_message: sanitize_text(value[:error_message]),
        diagnostics: sanitize_free_text(value[:diagnostics])
      }.compact

      evidence = evidence.except(:diagnostics) if evidence[:diagnostics].blank?
      evidence.presence
    end

    def log_tail_evidence(runs)
      Array(runs).first(EVIDENCE_MESSAGE_LIMIT).filter_map do |run|
        evidence = {
          run_id: read_attribute(run, :id),
          stdout: extract_log_tail(run, "stdout"),
          stderr: extract_log_tail(run, "stderr")
        }.compact

        evidence.except(:run_id).presence ? evidence : nil
      end
    end

    def extract_log_tail(run, log_type)
      logs = AgentRunLog.where(agent_run_id: read_attribute(run, :id), log_type: log_type)
        .order(created_at: :asc)
        .last(EVIDENCE_LOG_TAIL_LINE_LIMIT)

      content = logs.filter_map { |log| read_attribute(log, :content) }
        .join("\n")
      return if content.blank?

      sanitize_text(content.lines.last(EVIDENCE_LOG_TAIL_LINE_LIMIT).join.strip)
    end

    def runner_config_evidence(runs)
      Array(runs).filter_map do |run|
        snapshot_runner_config(run.respond_to?(:runner) ? run.runner : nil)
      end.uniq.first(EVIDENCE_RUNNER_CONFIG_LIMIT)
    end

    def snapshot_runner_config(runner)
      return if runner.blank?

      EVIDENCE_SAFE_RUNNER_CONFIG_FIELDS.each_with_object({}) do |field, snapshot|
        snapshot[field.to_sym] = sanitize_free_text(read_attribute(runner, field))
      end.merge(
        provider_api_key_configured: read_attribute(runner, :provider_api_key_id).present?
      ).compact
    end

    def aggregate_stats_for(runs)
      completed_at_values = Array(runs).filter_map { |run| read_attribute(run, :completed_at) }

      {
        run_count: runs.size,
        distinct_runners: Array(runs).flat_map { |run| distinct_runner_names_for(run) }.uniq.sort,
        statuses: Array(runs).group_by { |run| read_attribute(run, :status) }.transform_values(&:count),
        time_window: {
          started_at: completed_at_values.min&.iso8601,
          ended_at: completed_at_values.max&.iso8601,
          detector_window_hours: window_hours
        }
      }
    end

    def distinct_runner_names_for(run)
      names = Array(read_attribute(run, :runners_attempted)).filter_map do |attempt|
        sanitize_text(attempt.to_h["runner"] || attempt.to_h[:runner])
      end
      names << sanitize_text(read_attribute(run, :final_runner))
      names.compact.uniq
    end

    def sanitize_strings(values)
      values.filter_map { |value| sanitize_text(value) }
    end

    def sanitize_free_text(value)
      case value
      when Hash
        value.to_h.deep_symbolize_keys.each_with_object({}) do |(key, entry), sanitized|
          cleaned = sanitize_free_text(entry)
          sanitized[key] = cleaned if cleaned.present?
        end
      when Array
        value.filter_map { |entry| sanitize_free_text(entry) }.presence
      when String
        sanitize_text(value)
      else
        value
      end
    end

    def sanitize_text(value)
      return if value.blank?

      normalized = value.to_s
      normalized = normalized.delete("\x00") if normalized.encoding == Encoding::UTF_8 && normalized.valid_encoding?
      normalized = normalized.dup.force_encoding(Encoding::UTF_8).scrub.delete("\x00") unless normalized.valid_encoding?

      redacted = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
      AgentRun::RUNNER_ATTEMPT_SECRET_PATTERNS.reduce(redacted) do |result, (pattern, replacement)|
        result.gsub(pattern, replacement)
      end
    end

    def read_attribute(record, attribute)
      return unless record.respond_to?(attribute)

      record.public_send(attribute)
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

    def sort_patterns(patterns)
      patterns.sort_by do |pattern|
        [
          -severity_rank(pattern),
          pattern.goal.to_s,
          pattern.type.to_s,
          deduplication_suffix(pattern).to_s
        ]
      end
    end

    def severity_rank(pattern)
      pattern.severity == :error ? 1 : 0
    end

    def deduplication_suffix(pattern)
      return pattern.details[:error_pattern] if pattern.type == :error_cluster

      nil
    end
  end
end
