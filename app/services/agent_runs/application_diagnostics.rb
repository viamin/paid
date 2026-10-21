# frozen_string_literal: true

module AgentRuns
  # Read-only, bounded diagnostic evidence for the application exercised by one run.
  # @spec APP-DIAGNOSTICS-001
  # @spec APP-DIAGNOSTICS-002
  class ApplicationDiagnostics
    MAX_LOOKBACK_SECONDS = 3_600
    MAX_SAMPLES = 100
    METRIC_NAMES = %w[cpu_percent memory_bytes memory_limit_bytes memory_percent pids_count].freeze
    private_constant :METRIC_NAMES

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, lookback_seconds: MAX_LOOKBACK_SECONDS, limit: MAX_SAMPLES, now: Time.current)
      @agent_run = agent_run
      @lookback_seconds = bounded(lookback_seconds, MAX_LOOKBACK_SECONDS)
      @limit = bounded(limit, MAX_SAMPLES)
      @now = now
    end

    def call
      { "provenance" => provenance, "logs" => logs, "metrics" => metrics }
    end

    private

    def provenance
      {
        "account_id" => @agent_run.project.account_id,
        "project_id" => @agent_run.project_id,
        "agent_run_id" => @agent_run.id,
        "revision" => @agent_run.result_commit_sha || @agent_run.base_commit_sha,
        "queried_at" => @now.iso8601,
        "lookback_seconds" => @lookback_seconds
      }.compact
    end

    def logs
      verification = @agent_run.verification_result.to_h
      tail = verification["app_log_tail"].to_s
      return unavailable("application log was not captured by verification") if tail.blank?

      { "status" => "available", "entries" => [ {
        "timestamp" => verification["app_log_recorded_at"] || verification["recorded_at"],
        "content" => redact(tail),
        "truncated" => truthy?(verification["app_log_truncated"])
      } ] }
    end

    def truthy?(value)
      value == true || value == "true"
    end

    def metrics
      samples = @agent_run.container_metrics.where(recorded_at: since..@now).order(recorded_at: :desc).limit(@limit).map do |sample|
        {
          "recorded_at" => sample.recorded_at.iso8601,
          "cpu_percent" => sample.cpu_percent,
          "memory_bytes" => sample.memory_bytes,
          "memory_limit_bytes" => sample.memory_limit_bytes,
          "memory_percent" => sample.memory_percent,
          "pids_count" => sample.pids_count
        }.compact
      end.reverse
      return unavailable("no run-scoped application container samples are available") if samples.empty?

      { "status" => "available", "samples" => samples, "metric_names" => METRIC_NAMES }
    end

    def since
      @now - @lookback_seconds
    end

    def bounded(value, maximum)
      [ value.presence&.to_i || maximum, maximum ].min.clamp(1, maximum)
    end

    def unavailable(reason)
      { "status" => "unavailable", "reason" => reason }
    end

    def redact(text)
      AgentRuns::Research::SecretGuard.redact_text(text)
    end
  end
end
