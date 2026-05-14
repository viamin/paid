# frozen_string_literal: true

class CoordinationExperimentVariant < ApplicationRecord
  belongs_to :coordination_experiment

  has_many :coordination_experiment_assignments, dependent: :destroy

  validates :policy_config, presence: true
  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def parsed_policy
    policy_config.deep_dup
  end

  def effective_policy(control_policy:)
    control_policy.deep_dup.deep_merge(parsed_policy)
  end
end
