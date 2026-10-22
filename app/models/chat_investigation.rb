# frozen_string_literal: true

# @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
class ChatInvestigation < ApplicationRecord
  include TenantScoped

  KINDS = %w[research experiment].freeze
  STATUSES = %w[awaiting_authorization queued running completed failed cancelled].freeze
  ACTIVE_STATUSES = %w[queued running].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :chat_session
  belongs_to :clarifying_question_progress
  belongs_to :created_by, class_name: "User"

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :prompt, presence: true
  validates :estimated_cost_cents, :reserved_cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validate :account_matches_project
  validate :chat_session_belongs_to_project
  validate :question_belongs_to_chat_project

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  STATUSES.each do |value|
    define_method("#{value}?") { status == value }
  end

  private

  def account_matches_project
    return unless project
    return if project.account_id == account_id

    errors.add(:project, "must belong to the investigation account")
  end

  def chat_session_belongs_to_project
    return unless chat_session
    return if chat_session.project_id == project_id

    errors.add(:chat_session, "must belong to the investigation project")
  end

  def question_belongs_to_chat_project
    return unless clarifying_question_progress
    return if clarifying_question_progress.project_id == project_id && clarifying_question_progress.chat_session_id == chat_session_id

    errors.add(:clarifying_question_progress, "must belong to this chat session and project")
  end
end
