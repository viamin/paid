# frozen_string_literal: true

class OrchestrationDecision < ApplicationRecord
  belongs_to :project
  belongs_to :agent_run, optional: true

  before_validation :assign_project_from_agent_run

  validates :decision_type, presence: true, length: { maximum: 100 }
  validates :actor, presence: true, length: { maximum: 100 }
  validate :project_matches_agent_run
  validate :context_is_object
  validate :inputs_is_object
  validate :outputs_is_object
  validate :outcome_references_is_array

  scope :for_project, ->(project) { where(project: project) }
  scope :for_agent_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :by_decision_type, ->(decision_type) { where(decision_type: decision_type) }
  scope :by_actor, ->(actor) { where(actor: actor) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  private

  def assign_project_from_agent_run
    self.project ||= agent_run&.project
  end

  def project_matches_agent_run
    return unless project && agent_run
    return if project_id == agent_run.project_id

    errors.add(:project, "must match the agent run's project")
  end

  def context_is_object
    validate_json_object(:context)
  end

  def inputs_is_object
    validate_json_object(:inputs)
  end

  def outputs_is_object
    validate_json_object(:outputs)
  end

  def outcome_references_is_array
    return if outcome_references.is_a?(Array)

    errors.add(:outcome_references, "must be an array")
  end

  def validate_json_object(attribute)
    return if public_send(attribute).is_a?(Hash)

    errors.add(attribute, "must be an object")
  end
end
