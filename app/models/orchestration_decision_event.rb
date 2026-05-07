# frozen_string_literal: true

require "zlib"

class OrchestrationDecisionEvent < ApplicationRecord
  ACTIONS = %w[retry pause resume escalate].freeze
  STATUSES = %w[applied noop failed].freeze

  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :agent_run, optional: true

  before_validation :normalize_payloads
  before_validation :assign_sequence, on: :create

  validates :decision_point, presence: true
  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :sequence, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validate :issue_or_agent_run_present
  validate :issue_belongs_to_project, if: -> { issue.present? }
  validate :agent_run_belongs_to_project, if: -> { agent_run.present? }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :for_action, ->(action) { where(action: action) }
  scope :for_status, ->(status) { where(status: status) }

  def self.record!(project:, decision_point:, action:, status:, issue: nil, agent_run: nil, signals: {}, result: {})
    create!(
      project: project,
      issue: issue,
      agent_run: agent_run,
      decision_point: decision_point,
      action: action,
      status: status,
      signals: signals,
      result: result
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

  def normalize_payloads
    self.signals = (signals || {}).deep_stringify_keys
    self.result = (result || {}).deep_stringify_keys
  end

  def assign_sequence
    return if sequence.present? || project_id.blank? || action.blank?

    self.sequence = next_sequence
  end

  # Uses an advisory lock scoped to the (project, action, target) tuple to
  # prevent TOCTOU races where two concurrent record! calls read the same max
  # and assign duplicate sequence numbers.
  def next_sequence
    lock_key = Zlib.crc32("orch_decision:#{project_id}:#{action}:#{issue_id || "run:#{agent_run_id}"}")

    self.class.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key.to_i})")

    scope = self.class.where(project_id: project_id, action: action)

    scope = if issue_id.present?
      scope.where(issue_id: issue_id)
    else
      scope.where(issue_id: nil, agent_run_id: agent_run_id)
    end

    scope.maximum(:sequence).to_i + 1
  end

  def issue_or_agent_run_present
    return if issue.present? || agent_run.present?

    errors.add(:base, "issue or agent_run must be present")
  end

  def issue_belongs_to_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def agent_run_belongs_to_project
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end
end
