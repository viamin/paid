# frozen_string_literal: true

module ExceptionHandler
  # Classifies an exception by severity and recommended action based on
  # exception class, message patterns, and affected subsystem.
  #
  # Returns a Classification struct with :severity, :action, and :reason.
  class Classifier
    Classification = Data.define(:severity, :action, :reason)

    TRANSIENT_PATTERNS = [
      { class_pattern: /Net::OpenTimeout|Net::ReadTimeout|Timeout::Error/i, reason: "transient network timeout" },
      { class_pattern: /ConnectionReset|ConnectionRefused|BrokenPipe/i, reason: "transient network error" },
      { message_pattern: /rate.?limit/i, reason: "rate limiting" },
      { message_pattern: /temporarily unavailable/i, reason: "service temporarily unavailable" },
      { message_pattern: /connection timed out/i, reason: "connection timeout" }
    ].freeze

    P1_PATTERNS = [
      { class_pattern: /ActiveRecord::StatementInvalid/i, reason: "database statement error" },
      { message_pattern: /migration|schema/i, reason: "database schema issue" },
      { base_class: "PG::Error", reason: "database connection failure" },
      { base_class: "ActiveRecord::ConnectionNotEstablished", reason: "database connection failure" },
      { message_pattern: /data.?(?:loss|corrupt)/i, reason: "potential data integrity issue" }
    ].freeze

    SUBSYSTEM_SEVERITY = {
      "knowledge" => "p2",
      "agent_runs" => "p1",
      "github_sync" => "p2",
      "container_manager" => "p1",
      "secrets_proxy" => "p1",
      "general" => "p2"
    }.freeze

    # Keep issue filing conservative while preserving escalation for today's
    # intentionally loud subsystems.
    ISSUE_FILING_ALLOWLIST = %w[
      knowledge
      agent_runs
      container_manager
      secrets_proxy
    ].freeze

    def self.call(exception:, subsystem:)
      new(exception: exception, subsystem: subsystem).call
    end

    def initialize(exception:, subsystem:)
      @exception = exception
      @subsystem = subsystem
    end

    def call
      return transient_classification if transient?

      severity = determine_severity
      Classification.new(severity: severity, action: "issue_filed", reason: severity_reason)
    end

    private

    def transient?
      TRANSIENT_PATTERNS.any? { |pattern| matches?(pattern) }
    end

    def transient_classification
      pattern = TRANSIENT_PATTERNS.find { |p| matches?(p) }
      Classification.new(severity: "p2", action: "logged", reason: pattern[:reason])
    end

    def determine_severity
      return "p1" if p1_match?

      SUBSYSTEM_SEVERITY.fetch(@subsystem, "p2")
    end

    def p1_match?
      P1_PATTERNS.any? { |pattern| matches?(pattern) }
    end

    def severity_reason
      p1_pattern = P1_PATTERNS.find { |p| matches?(p) }
      return p1_pattern[:reason] if p1_pattern

      "#{@subsystem} subsystem exception"
    end

    def matches?(pattern)
      if pattern[:base_class]
        return false unless ancestor_match?(pattern[:base_class])
        return true unless pattern[:class_pattern] || pattern[:message_pattern]
      end

      class_matches = pattern[:class_pattern].nil? ||
        @exception.class.name.match?(pattern[:class_pattern])
      message_matches = pattern[:message_pattern].nil? ||
        @exception.message&.match?(pattern[:message_pattern])

      if pattern[:class_pattern] && pattern[:message_pattern]
        class_matches && message_matches
      elsif pattern[:class_pattern]
        class_matches
      else
        message_matches
      end
    end

    def ancestor_match?(base_class_name)
      klass = base_class_name.safe_constantize
      return false unless klass

      @exception.is_a?(klass)
    end
  end
end
