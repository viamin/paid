# frozen_string_literal: true

module Reviews
  module Verification
    # Output of the synthesis stage after mechanical validation: the review
    # body, the inline comments that survived the anchor and citation guards,
    # and the findings demoted to body bullets because they lost their anchor.
    #
    # @spec REVIEW-VERIFY-008
    ReviewDraft = Data.define(:body, :comments, :unanchored_bullets)
  end
end
