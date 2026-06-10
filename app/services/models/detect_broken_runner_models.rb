# frozen_string_literal: true

require "digest"

module Models
  # Reactive detector: sweeps recently failed agent runs for the model-error
  # signatures the orchestrator already recognizes at runtime
  # (RunAgentActivity::MODEL_NOT_FOUND_PATTERNS plus the Codex "requires a newer
  # version" message) and groups them into per-runner findings.
  #
  # Unlike DetectCatalogDrift, this catches models configured directly on Runner
  # records (e.g. opencode/pi tier_model_ids) and provider/CLI-version
  # mismatches — failures the registry-vs-catalog diff cannot see because the
  # provider/CLI itself is the authority that rejected the model.
  #
  # The caller is responsible for establishing tenant context (agent_runs are
  # RLS-scoped); ModelHealthCheckJob runs this under TenantContext.with_system_access.
  class DetectBrokenRunnerModels
    DEFAULT_LOOKBACK = 2.days
    MAX_RUN_IDS_PER_FINDING = 5
    MAX_RUNS_SCANNED = 2_000
    SAMPLE_MESSAGE_LIMIT = 500

    MODEL_NOT_FOUND = :model_not_found
    CLI_VERSION_OUTDATED = :cli_version_outdated

    ANSI_ESCAPE = /\e\[[0-9;]*m/
    MODEL_NOT_FOUND_PATTERNS = Activities::RunAgentActivity::MODEL_NOT_FOUND_PATTERNS
    CLI_VERSION_PATTERN = /requires a newer version of/i

    def self.call(...)
      new(...).call
    end

    def initialize(since: DEFAULT_LOOKBACK.ago)
      @since = since
    end

    def call
      findings = {}

      scanned_runs.each do |run|
        Array(run.runners_attempted).each do |attempt|
          finding = finding_for(attempt)
          next unless finding

          accumulate(findings, finding, run)
        end
      end

      Result.new(findings: findings.values.map { |f| finalize(f) })
    end

    private

    def scanned_runs
      AgentRun
        .where(status: AgentRun::TERMINAL_FAILURE_STATUSES)
        .where(updated_at: @since..)
        .order(updated_at: :desc)
        .limit(MAX_RUNS_SCANNED)
        .select(:id, :runners_attempted, :updated_at, :status)
    end

    def finding_for(attempt)
      return unless attempt.is_a?(Hash)
      return unless attempt["error_type"] == "error"

      message = clean(attempt["error_message"].to_s)
      return if message.blank?

      type = classify(message)
      return unless type

      runner_label = attempt["runner"].to_s
      {
        runner_label: runner_label,
        error_type: type,
        model: extract_model(message, type),
        message: message.truncate(SAMPLE_MESSAGE_LIMIT)
      }
    end

    def classify(message)
      return CLI_VERSION_OUTDATED if message.match?(CLI_VERSION_PATTERN)
      return MODEL_NOT_FOUND if MODEL_NOT_FOUND_PATTERNS.any? { |pattern| message.match?(pattern) }

      nil
    end

    def extract_model(message, type)
      if type == CLI_VERSION_OUTDATED
        return Regexp.last_match(1) if message.match(/The '([^']+)' model requires/)

        return "unknown"
      end

      provider_id = message[/providerID:\s*"([^"]*)"/, 1]
      model_id = message[/modelID:\s*"([^"]*)"/, 1]
      if provider_id.present?
        return [ provider_id, model_id.presence ].compact.join("/")
      end

      inline = message[/Model not found:\s*([^\s]+)/, 1]
      inline ? inline.sub(/[.\/]+\z/, "") : "unknown"
    end

    def accumulate(findings, finding, run)
      key = [ finding[:runner_label], finding[:error_type], finding[:model] ]
      entry = findings[key] ||= {
        runner_label: finding[:runner_label],
        error_type: finding[:error_type],
        model: finding[:model],
        sample_message: finding[:message],
        occurrences: 0,
        run_ids: []
      }
      entry[:occurrences] += 1
      entry[:run_ids] << run.id if entry[:run_ids].size < MAX_RUN_IDS_PER_FINDING
    end

    def finalize(finding)
      runner = resolve_runner(finding[:runner_label])
      finding.merge(
        runner_name: runner&.name || humanize_label(finding[:runner_label]),
        runner_key: runner&.runner_key || finding[:runner_label]
      )
    end

    def resolve_runner(runner_label)
      id = runner_label[/\Arunner:(\d+)\z/, 1]
      return Runner.find_by(id: id.to_i) if id

      Runner.find_by(runner_key: runner_label)
    end

    def humanize_label(runner_label)
      runner_label.sub(/\Arunner:/, "Runner ").tr("_", " ").titleize
    end

    def clean(message)
      message.to_s.gsub(ANSI_ESCAPE, "").strip
    end

    # Immutable view of the broken-runner findings.
    class Result
      attr_reader :findings

      def initialize(findings:)
        @findings = findings
      end

      def broken?
        @findings.any?
      end

      def fingerprint
        tokens = @findings.map { |f| "#{f[:runner_key]}:#{f[:error_type]}:#{f[:model]}" }
        Digest::SHA256.hexdigest(tokens.sort.join("|"))
      end

      def to_h
        { findings: @findings }
      end
    end
  end
end
