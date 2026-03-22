# frozen_string_literal: true

class Issue < ApplicationRecord
  PAID_STATES = %w[new planning in_progress completed failed].freeze
  PR_REVIEW_PHASES = %w[draft restarted ready merged escalated].freeze

  belongs_to :project
  belongs_to :parent_issue, class_name: "Issue", optional: true

  has_many :sub_issues, class_name: "Issue", foreign_key: :parent_issue_id,
                        inverse_of: :parent_issue, dependent: :nullify
  has_many :agent_runs, dependent: :nullify

  has_many :issue_dependencies, dependent: :destroy
  has_many :dependencies, through: :issue_dependencies, source: :depends_on_issue
  has_many :reverse_issue_dependencies, class_name: "IssueDependency",
                                        foreign_key: :depends_on_issue_id,
                                        dependent: :destroy,
                                        inverse_of: :depends_on_issue
  has_many :dependents, through: :reverse_issue_dependencies, source: :issue

  validates :github_issue_id, presence: true, uniqueness: { scope: :project_id }
  validates :github_number, presence: true
  validates :title, presence: true, length: { maximum: 1000 }
  validates :github_state, presence: true
  validates :github_creator_login, presence: true
  validates :github_created_at, presence: true
  validates :github_updated_at, presence: true
  validates :paid_state, presence: true, inclusion: { in: PAID_STATES }
  validates :pr_review_phase, inclusion: { in: PR_REVIEW_PHASES }, if: :is_pull_request?
  validate :parent_issue_belongs_to_same_project, if: -> { parent_issue.present? }

  after_commit :broadcast_current_section, on: [ :create, :destroy ]
  after_update_commit :broadcast_changed_sections
  after_commit :update_project_last_github_activity_at, on: [ :create, :update ]

  scope :by_paid_state, ->(state) { where(paid_state: state) }
  scope :root_issues, -> { where(parent_issue_id: nil) }
  scope :sub_issues_only, -> { where.not(parent_issue_id: nil) }
  scope :issues_only, -> { where(is_pull_request: false) }
  scope :pull_requests_only, -> { where(is_pull_request: true) }
  scope :ready_for_work, ->(project) {
    where(project: project, github_state: "open", is_pull_request: false)
      .where.not(
        id: IssueDependency
          .joins(:issue, :depends_on_issue)
          .where(
            depends_on_issue: { github_state: "open" },
            issues: { project_id: project.id }
          )
          .select(:issue_id)
      )
  }

  def github_url
    path = is_pull_request? ? "pull" : "issues"
    "#{project.github_url}/#{path}/#{github_number}"
  end

  def has_label?(label)
    labels.include?(label)
  end

  def trusted?
    project.trusted_github_user?(github_creator_login)
  end

  def untrusted?
    !trusted?
  end

  def sub_issue?
    parent_issue_id.present? || parent_issue.present?
  end

  def has_associated_pull_requests?
    if sub_issues.loaded?
      sub_issues.any?(&:is_pull_request?)
    else
      sub_issues.pull_requests_only.exists?
    end
  end

  def draft_phase?
    pr_review_phase.in?(%w[draft restarted])
  end

  def ready_phase?
    pr_review_phase == "ready"
  end

  def escalated_phase?
    pr_review_phase == "escalated"
  end

  def merged_phase?
    pr_review_phase == "merged"
  end

  def ready_to_work?
    blocking_issues.none?
  end

  def blocking_issues
    dependencies.where(github_state: "open")
  end

  def dependent_issues
    dependents
  end

  private

  def parent_issue_belongs_to_same_project
    return if parent_issue.project_id == project_id

    errors.add(:parent_issue, "must belong to the same project")
  end

  # During bulk sync (e.g. FetchIssuesActivity), this fires per-issue, but the
  # atomic WHERE clause ensures only the issue with the latest github_updated_at
  # actually modifies the project row — the rest are cheap no-op index lookups.
  def update_project_last_github_activity_at
    return unless github_updated_at_previously_changed?

    Project
      .where(id: project_id)
      .where("last_github_activity_at IS NULL OR last_github_activity_at < ?", github_updated_at)
      .update_all(last_github_activity_at: github_updated_at, updated_at: Time.current)
  end

  def broadcast_current_section
    if is_pull_request?
      project.broadcast_pull_requests_update
      project.broadcast_issues_update if parent_issue_id.present?
    else
      project.broadcast_issues_update
    end
  end

  def broadcast_changed_sections
    if saved_change_to_is_pull_request?
      project.broadcast_issues_update
      project.broadcast_pull_requests_update
    elsif is_pull_request?
      project.broadcast_pull_requests_update
      project.broadcast_issues_update if saved_change_to_parent_issue_id?
    else
      project.broadcast_issues_update
    end
  end
end
