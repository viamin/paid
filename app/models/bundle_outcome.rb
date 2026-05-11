# frozen_string_literal: true

class BundleOutcome < ApplicationRecord
  belongs_to :configuration_bundle
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: { scope: :configuration_bundle_id }
  validates :quality_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :metrics_is_object
  validate :agent_run_matches_bundle_scope, if: -> { configuration_bundle.present? && agent_run.present? }

  private

  def metrics_is_object
    return if metrics.is_a?(Hash)

    errors.add(:metrics, "must be an object")
  end

  def agent_run_matches_bundle_scope
    return if agent_run.project.account_id == configuration_bundle.account_id &&
      (configuration_bundle.project_id.nil? || agent_run.project_id == configuration_bundle.project_id)

    errors.add(:agent_run, "must belong to the same account and project scope as the configuration bundle")
  end
end
