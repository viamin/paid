# frozen_string_literal: true

require "digest"

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
    ANALYZE_ISSUE_PROVIDER_EXHAUSTION_PREFIX = "All issue-analysis providers exhausted"

    Pattern = Data.define(:type, :goal, :severity, :details)

    def self.call(...)
      new(...).call
    end

    def initialize(account:, window_hours: DEFAULT_WINDOW_HOURS)
      @account = account
      @window_hours = window_hours
      @log_tail_cache = {}
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
        details: with_fingerprint(
          goal: goal,
          type: :failure_streak,
          streak_length: streak.size,
          total_runs: runs.size,
          failure_rate: streak.size.to_f / runs.size,
          error_messages: streak.filter_map(&:error_message).first(5),
          evidence_bundle: build_evidence_bundle(streak),
          run_ids: streak.map(&:id),
          started_at: streak.last.completed_at,
          ended_at: streak.first.completed_at
        )
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
        details: with_fingerprint(
          goal: goal,
          type: :high_failure_rate,
          failure_count: failed,
          total_count: runs.size,
          failure_rate: failure_rate.round(4),
          baseline_rate: baseline&.round(4),
          error_messages: failed_runs.filter_map(&:error_message).first(5),
          evidence_bundle: build_evidence_bundle(failed_runs),
          run_ids: failed_runs.map(&:id)
        )
      ) ]
    end

    def detect_error_clusters(goal, runs)
      failed_runs = runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
      return [] if failed_runs.empty?

      provider_failure_categories = load_provider_failure_categories_by_run(failed_runs)
      by_normalized_error = failed_runs
        .select { |r| r.error_message.present? }
        .group_by { |r| error_pattern_for(r, provider_failure_categories: provider_failure_categories) }

      clusters = []
      by_normalized_error.each do |normalized_msg, error_runs|
        next unless error_runs.size >= ERROR_CLUSTER_MIN_SIZE

        error_run_ids = error_runs.map(&:id)
        clusters << Pattern.new(
          type: :error_cluster,
          goal: goal,
          severity: :error,
          details: with_fingerprint(
            goal: goal,
            type: :error_cluster,
            error_pattern: normalized_msg,
            occurrence_count: error_runs.size,
            total_failures: failed_runs.size,
            sample_messages: error_runs.map(&:error_message).compact.uniq.first(3),
            evidence_bundle: build_evidence_bundle(error_runs),
            run_ids: error_run_ids,
            statuses: error_runs.group_by(&:status).transform_values(&:count)
          ).merge(provider_failure_details(error_run_ids, normalized_msg))
        )
      end

      clusters
    end

    # Loads per-run structured failure categories, but only for analyze-issue
    # provider-exhaustion runs — the only ones whose cluster key derives from
    # AgentRunLog data instead of normalized error text — so goals without
    # exhaustion failures pay no extra query.
    def load_provider_failure_categories_by_run(failed_runs)
      exhaustion_run_ids = failed_runs
        .select { |run| analyze_issue_provider_exhaustion?(run, read_attribute(run, :error_message).to_s) }
        .filter_map { |run| read_attribute(run, :id) }
      return {} if exhaustion_run_ids.empty?

      AgentRunLog.provider_failure_categories_by_run(exhaustion_run_ids)
    end

    def error_pattern_for(run, provider_failure_categories:)
      message = read_attribute(run, :error_message)
      return if message.blank?

      return normalize_error(message) unless analyze_issue_provider_exhaustion?(run, message)

      exhaustion_error_pattern(provider_failure_categories[read_attribute(run, :id)])
    end

    def analyze_issue_provider_exhaustion?(run, message)
      read_attribute(run, :goal) == "analyze_issue" && message.start_with?(ANALYZE_ISSUE_PROVIDER_EXHAUSTION_PREFIX)
    end

    # Stable cluster key for provider-exhaustion failures: the exhaustion
    # prefix plus the run's sorted distinct failure categories. Provider names
    # and attempt counts never participate, so exhaustion incidents cluster on
    # the structured category regardless of which — or how many — providers
    # were attempted.
    def exhaustion_error_pattern(category_counts)
      categories = category_counts.to_h.keys.map(&:to_s).reject(&:blank?).sort
      [ ANALYZE_ISSUE_PROVIDER_EXHAUSTION_PREFIX, categories.join(", ").presence ].compact.join(": ")
    end

    # Attaches aggregated provider-failure categories to exhaustion clusters
    # only — the key is meaningless (and would cost a wasted query) for
    # clusters keyed on normalized free-text error messages.
    def provider_failure_details(run_ids, error_pattern)
      return {} unless error_pattern.start_with?(ANALYZE_ISSUE_PROVIDER_EXHAUSTION_PREFIX)

      { provider_failure_categories: provider_failure_category_counts_for(run_ids) }
    end

    def provider_failure_category_counts_for(run_ids)
      return {} if Array(run_ids).empty?

      AgentRunLog.provider_failure_categories(run_ids)
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
      sampled_runs = Array(runs).first(EVIDENCE_MESSAGE_LIMIT)
      log_tails = load_log_tails(sampled_runs)

      sampled_runs.filter_map do |run|
        run_id = read_attribute(run, :id)
        evidence = {
          run_id: run_id,
          stdout: sanitize_log_tail(log_tails[[ run_id, "stdout" ]]),
          stderr: sanitize_log_tail(log_tails[[ run_id, "stderr" ]])
        }.compact

        evidence.except(:run_id).presence ? evidence : nil
      end
    end

    def load_log_tails(runs)
      run_ids = Array(runs).filter_map { |run| read_attribute(run, :id) }
      return {} if run_ids.empty?

      @log_tail_cache[run_ids.sort] ||= begin
        tail_rows_for(run_ids).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |log, grouped_logs|
          key = [ read_attribute(log, :agent_run_id), read_attribute(log, :log_type) ]
          grouped_logs[key] << read_attribute(log, :content)
        end
      end
    end

    def tail_rows_for(run_ids)
      ranked_logs = AgentRunLog.where(agent_run_id: run_ids, log_type: %w[stdout stderr])
        .select(
          :agent_run_id,
          :log_type,
          :content,
          :created_at,
          :id,
          <<~SQL.squish
            ROW_NUMBER() OVER (
              PARTITION BY agent_run_id, log_type
              ORDER BY created_at DESC, id DESC
            ) AS row_number
          SQL
        )

      AgentRunLog.from("(#{ranked_logs.to_sql}) agent_run_log_tails")
        .where("row_number <= ?", EVIDENCE_LOG_TAIL_LINE_LIMIT)
        .select(:agent_run_id, :log_type, :content)
        .order(:agent_run_id, :log_type, created_at: :asc, id: :asc)
    end

    def sanitize_log_tail(log_lines)
      content = Array(log_lines).compact.join("\n")
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
        distinct_project_ids: Array(runs).filter_map { |run| read_attribute(run, :project_id) }.uniq.sort,
        distinct_runner_ids: Array(runs).filter_map { |run| read_attribute(run, :runner_id) }.uniq.sort,
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

    def with_fingerprint(goal:, type:, **details)
      aggregate_stats = details[:evidence_bundle].to_h.deep_symbolize_keys[:aggregate_stats] || {}

      details.merge(
        fingerprint: Digest::SHA256.hexdigest({
          goal: goal,
          type: type,
          error_pattern: details[:error_pattern],
          error_messages: Array(details[:error_messages]).sort,
          sample_messages: Array(details[:sample_messages]).sort,
          distinct_project_ids: Array(aggregate_stats[:distinct_project_ids]).sort,
          distinct_runner_ids: Array(aggregate_stats[:distinct_runner_ids]).sort
        }.to_json)
      )
    end
  end
end
