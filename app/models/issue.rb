# frozen_string_literal: true

class Issue < ApplicationRecord
  PAID_STATES = %w[new planning in_progress completed failed needs_input recommend_close].freeze
  PR_REVIEW_PHASES = %w[draft restarted ready merged escalated].freeze

  # Constants for synthetic alert issues. Shared with
  # Activities::ScanSecurityAlertsActivity which creates these issues.
  GITHUB_SOURCE = "github"
  SYNTHETIC_CODE_SCANNING_SOURCE = "code_scanning_alert"
  # Legacy source kept in VALID_SOURCES so existing Dependabot rows pass
  # validation on update (e.g. from agent-run completion activities).
  DEPENDABOT_ALERT_SOURCE = "dependabot_alert"
  VALID_SOURCES = [ GITHUB_SOURCE, SYNTHETIC_CODE_SCANNING_SOURCE, DEPENDABOT_ALERT_SOURCE ].freeze
  SEVERITY_ORDER = %w[critical high medium low].freeze
  TRACKER_PATTERN = /\b(?:tracker|remaining\s+work|completion\s+criteria|phase\s+tracker|meta\s+issue)\b/i
  # Large offset so synthetic github_issue_id values never collide with real
  # GitHub issue IDs (which currently range in the low billions).
  SYNTHETIC_CODE_SCANNING_ID_OFFSET = 800_000_000_000
  # Legacy offset for Dependabot synthetic issues. No new Dependabot issues are
  # created, but existing rows need this to generate correct github_url links.
  LEGACY_DEPENDABOT_ID_OFFSET = 900_000_000_000

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
  before_validation { self.source ||= GITHUB_SOURCE }
  validates :source, presence: true, inclusion: { in: VALID_SOURCES }
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
  scope :auto_continue_active, -> { where(auto_continue_paused: false) }
  scope :ready_for_work, ->(project) {
    blocked_by_local = IssueDependency
      .joins(:issue, :depends_on_issue)
      .where(
        depends_on_issue: { github_state: "open" },
        issues: { project_id: project.id }
      )
      .select(:issue_id)

    blocked_by_external = IssueDependency
      .joins(:issue)
      .where.not(depends_on_owner: nil)
      .where(issues: { project_id: project.id })
      .select(:issue_id)

    where(project: project, github_state: "open", is_pull_request: false)
      .where.not(id: blocked_by_local)
      .where.not(id: blocked_by_external)
  }

  def github_url
    # Legacy Dependabot synthetic issues link to the Dependabot alert page.
    # No new Dependabot issues are created, but existing rows use synthetic
    # github_number values that don't correspond to real GitHub issues.
    if source == DEPENDABOT_ALERT_SOURCE &&
       github_issue_id.present? &&
       github_issue_id >= LEGACY_DEPENDABOT_ID_OFFSET
      alert_number = github_issue_id - LEGACY_DEPENDABOT_ID_OFFSET
      return "#{project.github_url}/security/dependabot/#{alert_number}"
    end

    # Synthetic CodeQL alert issues link to the code scanning alert page.
    if source == SYNTHETIC_CODE_SCANNING_SOURCE &&
       github_issue_id.present? &&
       github_issue_id >= SYNTHETIC_CODE_SCANNING_ID_OFFSET
      alert_number = github_issue_id - SYNTHETIC_CODE_SCANNING_ID_OFFSET
      return "#{project.github_url}/security/code-scanning/#{alert_number}"
    end

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

  def tracker_issue?
    TRACKER_PATTERN.match?(title.to_s) || TRACKER_PATTERN.match?(body.to_s)
  end

  def body_referenced_issue_numbers
    body.to_s.scan(/(?<!\w)#(\d+)/).flatten.map(&:to_i).uniq
  end

  def closing_referenced_issue_numbers
    @closing_referenced_issue_numbers ||= parse_closing_references
  end

  def closed_issue(referenced_issues_by_number = {})
    closing_referenced_issue_numbers.each do |github_number|
      issue = referenced_issues_by_number[github_number]
      return issue if issue.present?
    end

    parent_issue
  end

  def has_associated_pull_requests?
    if sub_issues.loaded?
      sub_issues.any?(&:is_pull_request?)
    else
      sub_issues.pull_requests_only.exists?
    end
  end

  def associated_pull_request
    if sub_issues.loaded?
      open_prs = sub_issues.select { |si| si.is_pull_request? && si.github_state == "open" }
      return nil if open_prs.empty?

      open_prs.max_by do |pr|
        [ pr.github_updated_at || Time.at(0), pr.updated_at || Time.at(0) ]
      end
    else
      sub_issues.pull_requests_only
        .where(github_state: "open")
        .order(github_updated_at: :desc, updated_at: :desc)
        .first
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
    blocking_issues.none? && blocking_external_dependencies.none?
  end

  def blocking_issues
    dependencies.where(github_state: "open").where.not(paid_state: "recommend_close")
  end

  def blocking_external_dependencies
    issue_dependencies.where.not(depends_on_owner: nil)
  end

  def dependent_issues
    dependents
  end

  # Compute lifecycle statuses for a collection of issues.
  # Returns a Hash of issue_id => :blocked | :in_progress | :eligible
  def self.lifecycle_statuses(issues)
    issues = issues.to_a
    return {} if issues.empty?

    issue_ids = issues.map(&:id)

    # Match blocking_issues semantics: open dependencies excluding recommend_close
    blocked_by_local = IssueDependency
      .joins(:depends_on_issue)
      .where(issue_id: issue_ids, depends_on_issue: { github_state: "open" })
      .where.not(depends_on_issue: { paid_state: "recommend_close" })
      .pluck(:issue_id)
      .to_set

    # Match IssueDependency#external? semantics: owner+repo+number present, no local issue link
    blocked_by_external = IssueDependency
      .where(issue_id: issue_ids, depends_on_issue_id: nil)
      .where.not(depends_on_owner: [ nil, "" ])
      .where.not(depends_on_repo: [ nil, "" ])
      .where.not(depends_on_number: nil)
      .pluck(:issue_id)
      .to_set

    blocked_ids = blocked_by_local | blocked_by_external

    active_run_ids = AgentRun
      .where(issue_id: issue_ids, status: AgentRun::UNFINISHED_STATUSES)
      .pluck(:issue_id)
      .to_set

    has_open_pr_ids = Issue
      .where(parent_issue_id: issue_ids, is_pull_request: true, github_state: "open")
      .distinct
      .pluck(:parent_issue_id)
      .to_set

    in_progress_ids = active_run_ids | has_open_pr_ids

    issues.each_with_object({}) do |issue, hash|
      hash[issue.id] = if blocked_ids.include?(issue.id)
        :blocked
      elsif in_progress_ids.include?(issue.id)
        :in_progress
      else
        :eligible
      end
    end
  end

  private

  CLOSING_KEYWORD_RE = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b/i
  CLOSING_REF_RE = /\G\s*(?:,\s*)?(?:and\s+)?(?:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)|(?<!\w))#(\d+)/

  # Parses closing issue references that immediately follow a closing keyword,
  # consuming only chained references (separated by "," or "and"). Stops at the
  # first non-reference token so that e.g. "Closes #12, related to #14" only
  # returns [12].
  def parse_closing_references
    return [] if body.blank?

    numbers = []
    text = body.to_s
    text.scan(CLOSING_KEYWORD_RE) do
      pos = Regexp.last_match.end(0)
      # Skip optional colon after keyword (e.g. "Fixes: #123", "Closes: #123")
      pos += 1 if text[pos] == ":"
      while (m = CLOSING_REF_RE.match(text, pos))
        owner, repo, number = m[1], m[2], m[3]
        unless (owner.present? && !owner.casecmp?(project.owner)) ||
               (repo.present? && !repo.casecmp?(project.repo))
          numbers << number.to_i
        end
        pos = m.end(0)
      end
    end
    numbers.uniq
  end

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
