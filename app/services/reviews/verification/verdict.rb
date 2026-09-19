# frozen_string_literal: true

module Reviews
  module Verification
    # The verifier stage's judgement on one candidate. +verdict+ is one of
    # VERDICTS; +claim_key+ is the verifier-assigned identity of the underlying
    # claim used for mechanical deduplication. +corrected_path+/+corrected_line+
    # are set only when the verifier relocated the triggering line.
    #
    # @spec REVIEW-VERIFY-003
    class Verdict < Data.define(:candidate_id, :verdict, :evidence, :claim_key, :corrected_path, :corrected_line)
      VERDICTS = %i[confirmed plausible refuted].freeze

      def initialize(candidate_id:, verdict:, evidence:, claim_key:, corrected_path: nil, corrected_line: nil)
        super
      end

      def confirmed?
        verdict == :confirmed
      end
    end
  end
end
