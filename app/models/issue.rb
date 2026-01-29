# frozen_string_literal: true

class Issue < ApplicationRecord
  PAID_STATES = %w[new planning in_progress completed failed].freeze

  belongs_to :project
  belongs_to :parent_issue, class_name: "Issue", optional: true

  has_many :sub_issues, class_name: "Issue", foreign_key: :parent_issue_id,
                        inverse_of: :parent_issue, dependent: :nullify

  validates :github_issue_id, presence: true, uniqueness: { scope: :project_id }
  validates :github_number, presence: true
  validates :title, presence: true, length: { maximum: 1000 }
  validates :github_state, presence: true
  validates :github_created_at, presence: true
  validates :github_updated_at, presence: true
  validates :paid_state, presence: true, inclusion: { in: PAID_STATES }
  validate :parent_issue_belongs_to_same_project, if: -> { parent_issue.present? }

  scope :by_paid_state, ->(state) { where(paid_state: state) }
  scope :root_issues, -> { where(parent_issue_id: nil) }
  scope :sub_issues_only, -> { where.not(parent_issue_id: nil) }

  def github_url
    "#{project.github_url}/issues/#{github_number}"
  end

  def has_label?(label)
    labels.include?(label)
  end

  def sub_issue?
    parent_issue_id.present?
  end

  private

  def parent_issue_belongs_to_same_project
    return if parent_issue.project_id == project_id

    errors.add(:parent_issue, "must belong to the same project")
  end
end
