# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding"
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"

  validates :check_result_id, uniqueness: { scope: :finding_id }
  validates :observed_at, presence: true
end
