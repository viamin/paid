# frozen_string_literal: true

require "digest"

module ManualReviewRecovery
  # The revision of an issue's evidence that a manual-review decision is bound
  # to.
  #
  # A decision about an issue's intent must not silently cover a later edit of
  # that issue. The revision digests the issue's persisted content — its
  # title, body, and GitHub update timestamp — so any later change to the
  # issue produces a different revision and invalidates the recorded
  # decision.
  #
  # `github_updated_at` mirrors GitHub's own `updated_at`, so it moves only
  # when the issue actually changes on GitHub; a Paid-side write (a
  # `paid_state` flip, a label sync) leaves it alone and therefore does not
  # invalidate a decision the operator just made.
  # @spec MANUAL-REVIEW-RECOVERY-002
  class EvidenceRevision
    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      Digest::SHA256.hexdigest(payload.join("\u0000"))[0, 40]
    end

    private

    attr_reader :issue

    def payload
      [
        issue&.title.to_s,
        issue&.body.to_s,
        issue&.github_updated_at&.utc&.iso8601.to_s,
        issue&.github_state.to_s
      ]
    end
  end
end
