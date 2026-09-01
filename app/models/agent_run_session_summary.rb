# frozen_string_literal: true

# @spec SESSION-SUMMARY-001
class AgentRunSessionSummary < ApplicationRecord
  STATUSES = %w[observation promoted].freeze

  belongs_to :project
  belongs_to :agent_run
  belongs_to :issue, optional: true
  belongs_to :promoted_by, class_name: "User", optional: true
  belongs_to :change_intent, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :summary, presence: true
  validate :project_matches_agent_run
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :change_intent_belongs_to_same_project, if: -> { change_intent.present? }

  scope :for_project, ->(project) { where(project: project) }
  scope :observations, -> { where(status: "observation") }
  scope :promoted, -> { where(status: "promoted") }

  def observation?
    status == "observation"
  end

  def promoted?
    status == "promoted"
  end

  # @spec SESSION-SUMMARY-004
  def promote!(change_intent:, user:)
    with_lock do
      reload
      raise ArgumentError, "already promoted" if promoted?

      update!(status: "promoted", change_intent: change_intent, promoted_by: user, promoted_at: Time.current)
    end
  end

  private

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def change_intent_belongs_to_same_project
    return if change_intent.project_id == project_id

    errors.add(:change_intent, "must belong to the same project")
  end
end
