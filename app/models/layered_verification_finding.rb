# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015, LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze
  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id, dependent: :restrict_with_exception, inverse_of: :finding
  validates :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
end
