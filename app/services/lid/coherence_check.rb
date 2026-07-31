# frozen_string_literal: true

module Lid
  class CoherenceCheck
    CHECK_TIMEOUT_SECONDS = 60
    GOALS = %w[create_pr review lid_planning].freeze
    MARKER = "__PAID_LID_STATUS__"

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, container_service:, logger: Rails.logger)
      @agent_run = agent_run
      @container_service = container_service
      @logger = logger
    end

    def call
      return skipped_result("goal_not_supported") unless GOALS.include?(agent_run.goal)

      result = container_service.execute(command, timeout: CHECK_TIMEOUT_SECONDS, stream: false)
      output = [ result[:stdout], result[:stderr] ].compact.join("\n").strip

      marker_status = parse_marker(output)
      report = case marker_status
      when "skipped"
        skipped_result("not_lid_configured")
      when "unavailable"
        unavailable_result("missing_checker")
      else
        Lid::CoherenceReport.parse(output).to_h
      end

      persist(report)
      log_findings(report)
      report
    rescue StandardError => e
      report = unavailable_result("#{e.class.name}: #{e.message}")
      persist(report)
      logger.warn(
        message: "lid.coherence_check_failed",
        agent_run_id: agent_run.id,
        goal: agent_run.goal,
        error_class: e.class.name,
        error: e.message
      )
      report
    end

    private

    attr_reader :agent_run, :container_service, :logger

    def command
      [
        "bash",
        "-lc",
        <<~BASH
          if [ ! -f bin/coherence-check.mjs ]; then
            echo "#{MARKER} unavailable"
            exit 0
          fi

          if ! grep -q '^## LID' AGENTS.md 2>/dev/null \
            && ! grep -q '^## LID' CLAUDE.md 2>/dev/null \
            && [ ! -f docs/high-level-design.md ] \
            && [ ! -d docs/intent ]; then
            echo "#{MARKER} skipped"
            exit 0
          fi

          ./bin/coherence-check.mjs
        BASH
      ]
    end

    def parse_marker(output)
      output[/#{MARKER} (\w+)/, 1]
    end

    def skipped_result(reason)
      {
        "status" => "skipped",
        "summary_line" => "LID coherence check skipped: #{reason.tr('_', ' ')}."
      }
    end

    def unavailable_result(reason)
      {
        "status" => "unavailable",
        "summary_line" => "LID coherence check unavailable: #{reason}."
      }
    end

    def persist(report)
      metadata = agent_run.external_metadata.deep_dup
      metadata["lid_coherence"] = report
      agent_run.update!(external_metadata: metadata)
    end

    def log_findings(report)
      return unless report["status"] == "failed"

      agent_run.log!("system", report["summary_line"])
      logger.warn(
        message: "lid.coherence_soft_block",
        agent_run_id: agent_run.id,
        goal: agent_run.goal,
        summary: report["summary_line"]
      )
    end
  end
end
