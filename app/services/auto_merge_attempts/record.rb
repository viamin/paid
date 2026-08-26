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

    REASON_AUTO_MERGE_DISABLED = AutoMergeAttempt::REASON_AUTO_MERGE_DISABLED
    REASON_CHECKS_NOT_GREEN = AutoMergeAttempt::REASON_CHECKS_NOT_GREEN
    REASON_EXPECTED_MERGE_FAILURE = AutoMergeAttempt::REASON_EXPECTED_MERGE_FAILURE
    REASON_GRANULARITY_MISMATCH = AutoMergeAttempt::REASON_GRANULARITY_MISMATCH
    REASON_MERGE_PERMISSION_COOLDOWN = AutoMergeAttempt::REASON_MERGE_PERMISSION_COOLDOWN
    REASON_MISSING_WORKFLOWS_PERMISSION = AutoMergeAttempt::REASON_MISSING_WORKFLOWS_PERMISSION
    REASON_NOT_MERGEABLE = AutoMergeAttempt::REASON_NOT_MERGEABLE
    REASON_PARSE_FAILED = AutoMergeAttempt::REASON_PARSE_FAILED
    REASON_SKIP_LABEL = AutoMergeAttempt::REASON_SKIP_LABEL

    def self.call(...)
      new.call(...)
    end

    def call(project:, issue:, actor_path:, status:, reason_code: nil, message: nil,
      credential_mode: nil, attempted_at: Time.current)
      duplicate = duplicate_skip(issue, status, reason_code)
      return refresh_duplicate_skip(duplicate, attempted_at:, message:, credential_mode:) if duplicate

      AutoMergeAttempt.transaction(requires_new: true) do
        AutoMergeAttempt.create!(
          project: project,
          issue: issue,
          actor_path: actor_path,
          status: status,
          reason_code: reason_code,
          sanitized_message: sanitize_message(message),
          credential_mode: credential_mode,
          attempted_at: attempted_at
        )
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "auto_merge_attempts.record_failed",
        project_id: project.id,
        issue_id: issue.id,
        actor_path: actor_path,
        status: status,
        reason_code: reason_code,
        credential_mode: credential_mode,
        error_class: e.class.name
      )
      nil
    end

    private

    def duplicate_skip(issue, status, reason_code)
      return unless status == "skipped"

      latest = latest_attempt(issue)
      latest if latest&.status == status && latest.reason_code == reason_code
    end

    def latest_attempt(issue)
      issue.auto_merge_attempts.recent.first
    end

    def refresh_duplicate_skip(attempt, attempted_at:, message:, credential_mode:)
      AutoMergeAttempt.transaction(requires_new: true) do
        attempt.update!(
          attempted_at: attempted_at,
          sanitized_message: sanitize_message(message),
          credential_mode: credential_mode
        )
      end
      attempt
    end

    def sanitize_message(message)
      sanitized = AgentRun::ErrorMessageSanitizer.call(text: message)
      return sanitized if sanitized.blank?

      sanitized.lines.reject { |line| line.match?(STACK_TRACE_PATTERN) }.join.strip.presence
    end
  end
end
