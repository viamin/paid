# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding"
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult", optional: true
  belongs_to :agent_run, optional: true
end
