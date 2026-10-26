# frozen_string_literal: true

class LayeredVerificationCorrespondenceClaim < ApplicationRecord
  # @spec LAYERED-VERIFY-007
  CLAIM_TYPES = %w[business_to_model model_to_code business_to_spec spec_to_code business_to_test].freeze

  belongs_to :obligation, class_name: "LayeredVerificationObligation", inverse_of: :correspondence_claims
  has_many :check_results, class_name: "LayeredVerificationCheckResult",
    foreign_key: :correspondence_claim_id, dependent: :restrict_with_exception, inverse_of: :correspondence_claim

  validates :claim_type, inclusion: { in: CLAIM_TYPES }
  validates :source_reference, :target_reference, :abstraction_boundaries, :assumptions, presence: true
end
