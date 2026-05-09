# frozen_string_literal: true

class OrchestrationDecision < ApplicationRecord
  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :strategy_version, optional: true

  before_validation :assign_project_from_agent_run

  validates :decision_type, presence: true, length: { maximum: 100 }
  validates :actor, presence: true, length: { maximum: 100 }
  validate :project_matches_agent_run
  validate :strategy_version_matches_project_scope
  validate :context_is_object
  validate :inputs_is_object
  validate :outputs_is_object
  validate :outcome_references_is_array

  scope :for_project, ->(project) { where(project: project) }
  scope :for_agent_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :by_decision_type, ->(decision_type) { where(decision_type: decision_type) }
  scope :by_actor, ->(actor) { where(actor: actor) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Convenience factory for retry/escalation decision logging. Maps the
  # action/decision_point/signals/result interface used by orchestration
  # callers onto the generic OrchestrationDecision schema.
  def self.record!(project:, decision_point:, action:, status:, issue: nil, agent_run: nil, signals: {}, result: {})
    ctx = {}
    ctx[:issue_id] = issue.id if issue
    ctx[:decision_status] = status

    create!(
      project: project,
      agent_run: agent_run,
      decision_type: action,
      actor: decision_point,
      context: ctx,
      inputs: signals,
      outputs: result,
      outcome_references: []
    )
  end

  # Non-bang variant that silently swallows failures. Use this inside rescue
  # blocks or lifecycle transactions so a logging failure cannot mask the
  # original exception or poison the caller's transaction.
  def self.record(project:, decision_point:, action:, status:, issue: nil, agent_run: nil, signals: {}, result: {})
    transaction(requires_new: true) do
      record!(
        project: project, issue: issue, agent_run: agent_run,
        decision_point: decision_point, action: action, status: status,
        signals: signals, result: result
      )
    end
  rescue StandardError => e
    Rails.logger.warn(
      message: "orchestration_decision.record_failed",
      decision_point: decision_point,
      action: action,
      error_class: e.class.name,
      error_message: e.message
    )
    nil
  end

  private

  def assign_project_from_agent_run
    self.project ||= agent_run&.project
  end

  def project_matches_agent_run
    return unless project && agent_run
    return if project_id == agent_run.project_id

    errors.add(:project, "must match the agent run's project")
  end

  def strategy_version_matches_project_scope
    return unless project && strategy_version

    strategy = strategy_version.strategy
    return if strategy.account_id.nil?
    return if strategy.account_id == project.account_id && strategy.project_id.nil?
    return if strategy.account_id == project.account_id && strategy.project_id == project_id

    errors.add(:strategy_version, "must be global or scoped to the decision's account/project")
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
