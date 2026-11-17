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
    REQUIRED_FINDING_FIELDS = %w[category claim symbols locations verification_disposition].freeze
    DISPOSITIONS = MaintenanceFindingOccurrence::DISPOSITIONS
    ASSESSMENTS = MaintenanceFindingOccurrence::ASSESSMENTS

    def self.parse(output) = new(output).parse

    def initialize(output)
      @output = output.to_s
    end

    def parse
      payload = parse_payload
      validate_payload!(payload)
      attributes(payload)
    rescue JSON::ParserError => e
      raise InvalidReport, "maintenance report is not valid JSON: #{e.message}"
    end

    private

    attr_reader :output

    def parse_payload
      raw = output[REPORT_PATTERN, 1]
      raise InvalidReport, "maintenance report block is missing" if raw.blank?

      JSON.parse(raw.strip)
    end

    def validate_payload!(payload)
      raise InvalidReport, "maintenance report must be a JSON object" unless payload.is_a?(Hash)

      ARRAY_FIELDS.each { |field| require_type!(payload, field, Array) }
      require_type!(payload, "evidence", Hash)
      payload.fetch("findings").each { |finding| validate_finding!(finding) }
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
      return if finding["agent_assessment"].nil? || ASSESSMENTS.include?(finding["agent_assessment"])

      raise InvalidReport, "finding agent assessment is invalid"
    end

    def validate_persistence_bounds!(finding)
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
        findings: payload.fetch("findings").map { |finding| finding.deep_symbolize_keys }
      }
    end
  end
end
