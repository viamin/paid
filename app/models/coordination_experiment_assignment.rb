# frozen_string_literal: true

class CoordinationExperimentAssignment < ApplicationRecord
  OUTCOME_STATUSES = %w[assigned recorded].freeze

  belongs_to :coordination_experiment
  belongs_to :coordination_experiment_variant
  belongs_to :project
  belongs_to :issue, optional: true

  validates :workflow_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: :coordination_experiment_id }
  validates :outcome_status, inclusion: { in: OUTCOME_STATUSES }
  validate :variant_matches_experiment

  scope :recorded, -> { where(outcome_status: "recorded") }

  private

  def variant_matches_experiment
    return if coordination_experiment_variant.nil? || coordination_experiment.nil?
    return if coordination_experiment_variant.coordination_experiment_id == coordination_experiment_id

    errors.add(:coordination_experiment_variant, "must belong to the same experiment")
  end
end
