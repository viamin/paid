# frozen_string_literal: true

class BundleOutcome < ApplicationRecord
  belongs_to :configuration_bundle
  belongs_to :agent_run
  belongs_to :project

  validates :outcome_score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validate :json_columns_are_objects
  validate :project_matches_agent_run
  validate :bundle_is_visible_to_project_account

  before_validation :sync_project_from_agent_run

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_training, -> { includes(:configuration_bundle).order(:id) }

  private

  def sync_project_from_agent_run
    self.project = agent_run&.project if agent_run.present?
  end

  def json_columns_are_objects
    %i[context_features component_scores].each do |column|
      next if public_send(column).is_a?(Hash)

      errors.add(column, "must be a JSON object")
    end
  end

  def project_matches_agent_run
    return if agent_run.nil? || project_id == agent_run.project_id

    errors.add(:project, "must match the agent run project")
  end

  def bundle_is_visible_to_project_account
    return if configuration_bundle.nil? || project.nil?
    return if configuration_bundle.account_id.nil?
    return if configuration_bundle.account_id == project.account_id

    errors.add(:configuration_bundle, "must belong to the same account as the project")
  end
end
