# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding", foreign_key: :finding_id
  belongs_to :agent_run, optional: true

  validates :revision, presence: true
end
