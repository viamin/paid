# frozen_string_literal: true

module MaintenanceReports
  # Parses the structured maintenance report emitted in the agent's final
  # output. Semantic assessment remains with the agent; this boundary only
  # validates the shape required for durable persistence.
  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  class AgentReport
    class InvalidReport < StandardError; end

    REPORT_PATTERN = /<!--\s*maintenance-report-start\s*-->\n?(.*?)\n?<!--\s*maintenance-report-end\s*-->/m.freeze
    ARRAY_FIELDS = %w[exclusions completed_checks incomplete_checks findings].freeze
    REQUIRED_FINDING_FIELDS = %w[
      category claim symbols locations evidence_source analyzer_provenance verification_disposition
    ].freeze
    DISPOSITIONS = MaintenanceFindingOccurrence::DISPOSITIONS
    ASSESSMENTS = MaintenanceFindingOccurrence::ASSESSMENTS
    EVIDENCE_SOURCES = %w[agent tool].freeze

    def self.parse(output) = new(output).parse

    def initialize(output)
      @output = output.to_s
    end

    def parse
      payload = parse_payload
      validate_payload!(payload)
      attributes(payload)
    rescue JSON::ParserError
      raise InvalidReport, "maintenance report is not valid JSON"
    end

    private

    attr_reader :output

    def parse_payload
      last_start = output.rindex(/<!--\s*maintenance-report-start\s*-->/)
      last_end = output.rindex(/<!--\s*maintenance-report-end\s*-->/)
      if last_start && (last_end.nil? || last_start > last_end)
        raise InvalidReport, "maintenance report is truncated"
      end
      raw = output.scan(REPORT_PATTERN).last&.first
      raise InvalidReport, "maintenance report block is missing" if raw.blank?

      JSON.parse(raw.strip)
    end

    def validate_payload!(payload)
      raise InvalidReport, "maintenance report must be a JSON object" unless payload.is_a?(Hash)

      ARRAY_FIELDS.each { |field| require_type!(payload, field, Array) }
      require_type!(payload, "evidence", Hash)
      unless payload["resolved_scope"].nil? || payload["resolved_scope"].is_a?(String)
        raise InvalidReport, "maintenance report resolved_scope must be a string"
      end
      payload.fetch("findings").each { |finding| validate_finding!(finding) }
      if payload.fetch("completed_checks").empty? && payload.fetch("incomplete_checks").empty?
        raise InvalidReport, "maintenance report must disclose at least one completed or incomplete check"
      end
    end

    def validate_finding!(finding)
      raise InvalidReport, "each finding must be a JSON object" unless finding.is_a?(Hash)

      missing = REQUIRED_FINDING_FIELDS.reject { |field| finding.key?(field) }
      raise InvalidReport, "finding is missing: #{missing.join(', ')}" if missing.any?
      raise InvalidReport, "finding claim must be a string" unless finding["claim"].is_a?(String)
      raise InvalidReport, "finding category and claim must be present" if finding.values_at("category", "claim").any?(&:blank?)
      raise InvalidReport, "finding symbols and locations must be arrays" unless finding["symbols"].is_a?(Array) && finding["locations"].is_a?(Array)
      raise InvalidReport, "finding verification disposition is invalid" unless DISPOSITIONS.include?(finding["verification_disposition"])
      validate_persistence_bounds!(finding)
      %w[supporting_evidence contrary_evidence].each do |field|
        next unless finding.key?(field)

        require_type!(finding, field, Array)
      end
      validate_analyzer_provenance!(finding)
      return if finding["agent_assessment"].nil? || ASSESSMENTS.include?(finding["agent_assessment"])

      raise InvalidReport, "finding agent assessment is invalid"
    end

    def validate_analyzer_provenance!(finding)
      require_type!(finding, "analyzer_provenance", Hash)
      provenance = finding.fetch("analyzer_provenance")
      return if finding["evidence_source"] == "agent" && provenance.empty?

      raise InvalidReport, "tool-derived finding analyzer_provenance must not be empty" if provenance.empty?

      missing = %w[name version configuration].reject { |field| provenance[field].present? }
      raise InvalidReport, "finding analyzer_provenance is missing: #{missing.join(', ')}" if missing.any?
    end

    def validate_persistence_bounds!(finding)
      unless EVIDENCE_SOURCES.include?(finding["evidence_source"])
        raise InvalidReport, "finding evidence source is invalid"
      end
      confidence = finding["raw_tool_confidence"]
      unless confidence.nil? || (confidence.is_a?(Numeric) && confidence.between?(0, 1))
        raise InvalidReport, "finding raw_tool_confidence must be a number between 0 and 1"
      end
      unless finding["category"].is_a?(String) && finding["category"].length <= 100
        raise InvalidReport, "finding category must be a string of at most 100 characters"
      end
    end

    def require_type!(payload, field, type)
      return if payload[field].is_a?(type)

      raise InvalidReport, "maintenance report #{field} must be #{type.name.downcase}"
    end

    def attributes(payload)
      {
        resolved_scope: payload["resolved_scope"].presence,
        exclusions: payload.fetch("exclusions"),
        completed_checks: payload.fetch("completed_checks"),
        incomplete_checks: payload.fetch("incomplete_checks"),
        evidence: payload.fetch("evidence"),
        findings: payload.fetch("findings").map(&:deep_symbolize_keys)
      }
    end
  end
end
