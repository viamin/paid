# frozen_string_literal: true

class ClarifyingQuestionProgress < ApplicationRecord
  include TenantScoped

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :chat_session
  belongs_to :answered_by, class_name: "User", optional: true

  validates :question, :question_digest, :position, presence: true
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :position, uniqueness: { scope: [ :issue_id, :question_digest ] }
  validate :issue_belongs_to_project
  validate :project_belongs_to_account
  validate :chat_belongs_to_issue

  scope :ordered, -> { order(:position) }
  scope :answered, -> { where.not(answer: [ nil, "" ]) }

  private

  def issue_belongs_to_project
    errors.add(:issue, "must belong to the progress project") if issue && issue.project_id != project_id
  end

  def project_belongs_to_account
    errors.add(:project, "must belong to the progress account") if project && project.account_id != account_id
  end

  def chat_belongs_to_issue
    return unless chat_session
    return if chat_session.clarifying_question_issue_id == issue_id

    errors.add(:chat_session, "must be linked to the progress issue")
  end
end
