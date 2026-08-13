# frozen_string_literal: true

module Github
  # Marker injected into review-goal review bodies so Paid can recognize reviews
  # it posted, even when they arrive through a path that bypasses the proxy's
  # tracking (see Activities::CompleteReviewGoalActivity reconciliation).
  #
  # Producer: Api::GithubProxyController#maybe_prepend_review_header
  # Consumer: Activities::CompleteReviewGoalActivity#paid_marked_review?
  #
  # Keep this as the single source of truth so the producer and consumer never
  # drift apart. If the marker text changes, both sides update in lockstep.
  module ReviewMarker
    PAID_REVIEW_MARKER = "<!-- paid:code-review -->"
  end
end
