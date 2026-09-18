# frozen_string_literal: true

module Reviews
  module Verification
    # One deduplication group of confirmed candidates sharing +(path, claim_key)+.
    # +members+ is an array of +{ candidate:, verdict: }+ hashes. +anchor_line+
    # is nil when no member's location is a valid changed line of the pinned
    # head, in which case the finding can only be surfaced in the review body.
    #
    # @spec REVIEW-VERIFY-005
    ConfirmedFinding = Data.define(:id, :anchor_path, :anchor_line, :claim_key, :members) do
      def candidate_ids
        members.map { |member| member[:candidate].id }
      end

      def summary
        members.first[:candidate].summary
      end

      def anchored?
        anchor_line.present?
      end
    end
  end
end
