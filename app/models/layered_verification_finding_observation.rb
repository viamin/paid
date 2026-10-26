# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  belongs_to :finding, class_name: "LayeredVerificationFinding", inverse_of: :observations
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"
  belongs_to :agent_run

  validates :check_result_id, uniqueness: { scope: :finding_id }
end
