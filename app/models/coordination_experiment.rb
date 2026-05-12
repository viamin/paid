# frozen_string_literal: true

require "zlib"

class CoordinationExperiment < ApplicationRecord
  STATUSES = %w[draft running completed cancelled].freeze
  POLICY_NAME = "feature_orchestration"

  belongs_to :account
  belongs_to :winner_variant, class_name: "CoordinationExperimentVariant", optional: true

  has_many :coordination_experiment_variants, dependent: :destroy
  has_many :coordination_experiment_assignments, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :policy_name, presence: true, inclusion: { in: [ POLICY_NAME ] }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :control_policy, presence: true
  validates :min_samples_per_variant, numericality: { only_integer: true, greater_than_or_equal_to: 2 }
  validates :traffic_percentage, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validate :winner_variant_belongs_to_experiment

  scope :running, -> { where(status: "running") }

  def self.active_for(account:, workflow_id:)
    experiment = running.where(account:, policy_name: POLICY_NAME).order(:id).first
    return nil unless experiment
    return nil unless experiment.includes_traffic?(workflow_id:)

    experiment
  end

  def running?
    status == "running"
  end

  def control_variant
    coordination_experiment_variants.find_by(is_control: true)
  end

  def baseline_policy
    OrchestrationStrategies::Defaults.feature_orchestration.deep_merge(control_policy.deep_dup)
  end

  def effective_policy_for(variant)
    return baseline_policy if variant.nil?

    variant.effective_policy(control_policy: baseline_policy)
  end

  def includes_traffic?(workflow_id:)
    return false if traffic_percentage.zero?
    return true if traffic_percentage == 100

    Zlib.crc32("#{id}:#{workflow_id}") % 100 < traffic_percentage
  end

  private

  def winner_variant_belongs_to_experiment
    return if winner_variant.nil?
    return if winner_variant.coordination_experiment_id == id

    errors.add(:winner_variant, "must belong to this experiment")
  end
end
