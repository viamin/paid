# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::ReviewMarker do
  describe "producer/consumer coupling" do
    # The marker is injected into review-goal review bodies by the GitHub proxy
    # and matched by review reconciliation. They must agree byte-for-byte, so
    # both sides reference this single constant. Guard against someone
    # re-introducing a free-standing literal on either side.
    it "the proxy and reconciliation activity share the same marker" do
      expect(Api::GithubProxyController::REVIEW_COMMENT_MARKER)
        .to eq(described_class::PAID_REVIEW_MARKER)
      expect(Activities::CompleteReviewGoalActivity::PAID_REVIEW_MARKER)
        .to eq(described_class::PAID_REVIEW_MARKER)
    end
  end
end
