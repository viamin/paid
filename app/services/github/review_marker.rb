# frozen_string_literal: true

module Github
  # Marker injected into review-goal review bodies so Paid can recognize reviews
  # it posted, even when they arrive through a path that bypasses the proxy's
  # tracking (see Activities::CompleteReviewGoalActivity reconciliation).
  #
  # Producer: Api::GithubProxyController#maybe_prepend_review_header and
  # Reviews::Verification::PostTrackedReview (the control-plane pilot path)
  # Consumer: Activities::CompleteReviewGoalActivity#paid_marked_review?
  #
  # Keep this as the single source of truth so the producers and consumer never
  # drift apart. If the marker text changes, all sides update in lockstep.
  module ReviewMarker
    PAID_REVIEW_MARKER = "<!-- paid:code-review -->"
    REVIEW_HEADER = "## Code Review"

    # Prefix every Paid-authored review body carries: the machine marker first,
    # then the human-visible header. Shared by the container proxy path and the
    # verified-review pipeline so both post indistinguishable review bodies.
    def self.body_prefix
      "#{PAID_REVIEW_MARKER}\n#{REVIEW_HEADER}\n\n"
    end
  end
end
