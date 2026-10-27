# frozen_string_literal: true

module ManualReviewRecovery
  # Why an issue is parked in `manual_review`.
  #
  # The class classifies from the provenance the parking producer already
  # recorded — the dedicated reopen-review reason, the producer's own reason
  # wording, and the issue's structural state — and never from a guess about
  # what the text means. An unresolved cause stays `unknown` and visible.
  # @spec MANUAL-REVIEW-RECOVERY-001
  class Cause
    REOPEN_REVIEW = "reopen_review"
    DEPENDENCY_WAIT = "dependency_wait"
    ENHANCEMENT = "enhancement"
    SCANNER_RECURRENCE = "scanner_recurrence"
    TECHNICAL_FAILURE = "technical_failure"
    UNKNOWN = "unknown"

    CODES = [
      REOPEN_REVIEW,
      DEPENDENCY_WAIT,
      ENHANCEMENT,
      SCANNER_RECURRENCE,
      TECHNICAL_FAILURE,
      UNKNOWN
    ].freeze

    LABELS = {
      REOPEN_REVIEW => "Reopened after closure",
      DEPENDENCY_WAIT => "Waiting on a dependency",
      ENHANCEMENT => "Enhancement stopped",
      SCANNER_RECURRENCE => "Scanner-confirmed recurrence",
      TECHNICAL_FAILURE => "Technical failure",
      UNKNOWN => "Unclassified manual review"
    }.freeze

    # Reused from the Inbox phase ownership rules so "an enhancement stopped
    # this" is classified the same way wherever it is read.
    ENHANCEMENT_REASON_PATTERN = /enhance|clarif|question/i

    attr_reader :code

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      @code = detect_code
      self
    end

    # The producer's recorded reason, shown next to the classified cause.
    def reason
      recorded_reason
    end

    def label
      LABELS.fetch(code)
    end

    def known?
      code != UNKNOWN
    end

    def reopen_review?
      code == REOPEN_REVIEW
    end

    def dependency_wait?
      code == DEPENDENCY_WAIT
    end

    def enhancement?
      code == ENHANCEMENT
    end

    def scanner_recurrence?
      code == SCANNER_RECURRENCE
    end

    def technical_failure?
      code == TECHNICAL_FAILURE
    end

    def unknown?
      code == UNKNOWN
    end

    private

    attr_reader :issue

    # Order matters. Structural provenance wins first (an issue reopened
    # after closure keeps the reopen-review reason whatever else happened
    # since), then the producers' own wording, and only then the broad
    # enhancement wording — which also matches the malformed-output reason,
    # so the technical signatures have to be checked before it.
    def detect_code
      return REOPEN_REVIEW if issue&.reopen_review_pending?
      return UNKNOWN unless issue

      if code_scanning_issue?
        return TECHNICAL_FAILURE if technical_reason?
        return SCANNER_RECURRENCE
      end

      return DEPENDENCY_WAIT if reason_includes?(ReasonSignatures::DEPENDENCY_WAIT)
      return TECHNICAL_FAILURE if technical_reason?
      return ENHANCEMENT if enhancement_reason?

      UNKNOWN
    end

    def code_scanning_issue?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE
    end

    def technical_reason?
      reason_includes?(ReasonSignatures::ENHANCEMENT_OUTPUT_INVALID) ||
        reason_includes?(ReasonSignatures::SCANNER_EVIDENCE_BLOCKED) ||
        reason_includes?(ReasonSignatures::SCANNER_EVIDENCE_REFRESH_FAILED)
    end

    def enhancement_reason?
      reason_includes?(ReasonSignatures::ENHANCEMENT_ROUND_LIMIT) ||
        reason_includes?(ReasonSignatures::ENHANCEMENT_QUEUE_LIMIT) ||
        recorded_reason.match?(ENHANCEMENT_REASON_PATTERN)
    end

    def reason_includes?(fragment)
      recorded_reason.include?(fragment)
    end

    def recorded_reason
      @recorded_reason ||= issue&.manual_review_reason.to_s
    end
  end
end
