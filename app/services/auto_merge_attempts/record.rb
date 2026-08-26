# frozen_string_literal: true

module AutoMergeAttempts
  # @spec AUTO-MERGE-004
  class Record
    ACTOR_AUTO_RELEASE = "auto_release"
    ACTOR_DEPENDABOT_AUTO_MERGE = "dependabot_auto_merge"
    ACTOR_REVIEW_AUTO_MERGE = "review_auto_merge"

    # Ruby/Rails backtrace frames ("app/models/foo.rb:12:in `bar'" and
    # continuation lines starting with "from ...").
    STACK_TRACE_PATTERN = %r{\A\s*(?:from\s+)?[\w.\-/]+\.rb:\d+:in\s+`}.freeze

    REASON_AUTO_MERGE_DISABLED = "auto_merge_disabled"
    REASON_CHECKS_NOT_GREEN = "checks_not_green"
    REASON_EXPECTED_MERGE_FAILURE = "expected_merge_failure"
    REASON_GRANULARITY_MISMATCH = "granularity_mismatch"
    REASON_MERGE_PERMISSION_COOLDOWN = "merge_permission_cooldown"
    REASON_MISSING_WORKFLOWS_PERMISSION = "missing_workflows_permission"
    REASON_NOT_MERGEABLE = "not_mergeable"
    REASON_PARSE_FAILED = "parse_failed"
    REASON_SKIP_LABEL = "skip_label"

    def self.call(...)
      new.call(...)
    end

    def call(project:, issue:, actor_path:, status:, reason_code: nil, sanitized_message: nil, message: nil,
      credential_mode: nil, attempted_at: Time.current)
      AutoMergeAttempt.create!(
        project: project,
        issue: issue,
        actor_path: actor_path,
        status: status,
        reason_code: reason_code,
        sanitized_message: sanitize_message(message || sanitized_message),
        credential_mode: credential_mode,
        attempted_at: attempted_at
      )
    end

    private

    def sanitize_message(message)
      sanitized = AgentRun::ErrorMessageSanitizer.call(text: message)
      return sanitized if sanitized.blank?

      sanitized.lines.reject { |line| line.match?(STACK_TRACE_PATTERN) }.join.strip.presence
    end
  end
end
