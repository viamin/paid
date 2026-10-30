# frozen_string_literal: true

# A planning label written through an agent's GitHub proxy. Unlike a label
# itself, this record carries the authority needed to decide whether Paid may
# later remove it.
class AgentPlanningHold < ApplicationRecord
  STATUSES = %w[needs_review held released reconciliation_failed].freeze
  SUPPORTED_RELEASE_CONDITION_KINDS = %w[agent_run_finished dependencies_resolved issue_closed].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :agent_run, optional: true

  validates :label, presence: true
  validates :remote_issue_number, presence: true
  validates :status, inclusion: { in: STATUSES }
  before_validation :set_remote_issue_number
  validate :project_belongs_to_account
  validate :issue_belongs_to_project
  validate :agent_run_belongs_to_project

  def paid_owned?
    task_kind.present? && reason.present? && release_condition.present? && evidence["scope_revision"].present?
  end

  def releasable?
    paid_owned? && !operator_override? && status.in?(%w[held reconciliation_failed])
  end

  def supported_release_condition?
    release_condition["kind"].in?(SUPPORTED_RELEASE_CONDITION_KINDS)
  end

  private

  def project_belongs_to_account
    errors.add(:project, "must belong to the account") if project && account && project.account_id != account_id
  end

  def issue_belongs_to_project
    errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project_id
  end

  def agent_run_belongs_to_project
    errors.add(:agent_run, "must belong to the project") if agent_run && project && agent_run.project_id != project_id
  end

  def set_remote_issue_number
    self.remote_issue_number ||= issue&.github_number
  end
end
