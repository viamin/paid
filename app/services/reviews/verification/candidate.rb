# frozen_string_literal: true

module Reviews
  module Verification
    # A candidate finding produced by the finder stage (#3898). Every field is
    # required: the location anchors the claim to the diff, and the three
    # evidence fields are what the verifier stage inspects.
    #
    # @spec REVIEW-VERIFY-002
    Candidate = Data.define(:id, :path, :line, :summary, :triggering_condition, :failure_scenario)
  end
end
