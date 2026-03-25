# frozen_string_literal: true

class Project < ApplicationRecord
  MERGE_METHODS = %w[squash merge rebase].freeze

  belongs_to :account
  belongs_to :github_token
  belongs_to :created_by, class_name: "User", optional: true

  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user
  has_many :issues, dependent: :destroy
  has_many :agent_runs, dependent: :destroy
  has_many :worktrees, dependent: :destroy
  has_many :cost_budgets, dependent: :destroy
  has_many :token_usages, through: :agent_runs
  has_many :workflow_states, dependent: :destroy
  has_many :prompts, dependent: :destroy
  has_many :style_guides, dependent: :destroy
  has_many :project_service_containers, dependent: :destroy
  has_many :service_containers, through: :project_service_containers

  validates :name, presence: true
  validates :owner, presence: true
  validates :repo, presence: true
  validates :github_id, presence: true, uniqueness: { scope: :account_id }
  validates :poll_interval_seconds, numericality: { greater_than_or_equal_to: 60 }
  validates :max_pr_followup_runs, numericality: { greater_than_or_equal_to: 0 }
  validates :merge_method, inclusion: { in: MERGE_METHODS }
  validates :max_draft_review_rounds, numericality: { greater_than_or_equal_to: 0 }
  validate :allowed_github_usernames_not_empty
  validate :owner_reviewer_login_is_trusted, if: -> { owner_reviewer_login.present? }
  validate :github_token_belongs_to_same_account, if: -> { github_token.present? }
  validate :github_token_is_active, if: -> { github_token.present? && github_token_id_changed? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  def self.ransackable_attributes(auth_object = nil)
    %w[name last_agent_run_at last_github_activity_at created_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[]
  end

  after_create_commit :start_github_polling
  after_update_commit :toggle_github_polling, if: :saved_change_to_active?
  after_update_commit :trigger_auto_pick, if: :auto_pick_just_enabled?
  after_destroy_commit :stop_github_polling

  def full_name
    "#{owner}/#{repo}"
  end

  def github_url
    "https://github.com/#{full_name}"
  end

  def activate!
    update!(active: true)
  end

  def deactivate!
    update!(active: false)
  end

  def label_for_stage(stage)
    label_mappings[stage.to_s]
  end

  def set_label_for_stage(stage, label)
    self.label_mappings = label_mappings.merge(stage.to_s => label)
  end

  def worktree_service
    @worktree_service ||= WorktreeService.new(self)
  end

  def create_worktree_for(agent_run)
    worktree_service.create_worktree(agent_run)
  end

  def remove_worktree_for(agent_run)
    worktree_service.remove_worktree(agent_run)
  end

  def push_branch_for(agent_run)
    worktree_service.push_branch(agent_run)
  end

  # Returns the set of PR numbers that have queued automatic agent runs,
  # used by both the controller and Turbo broadcasts to drive the "Bump Priority" UI.
  def pr_numbers_with_queued_auto_continue
    agent_runs
      .where(trigger_type: "automatic", status: "queued")
      .where.not(source_pull_request_number: nil)
      .distinct
      .pluck(:source_pull_request_number)
      .to_set
  end

  # Returns the set of PR numbers that have any active (queued/pending/running) agent run,
  # used to suppress "Quick Run" when a run is already in progress (unique index would reject it).
  def pr_numbers_with_active_runs
    agent_runs
      .where(status: %w[queued pending running])
      .where.not(source_pull_request_number: nil)
      .distinct
      .pluck(:source_pull_request_number)
      .to_set
  end

  def has_running_database_container?
    service_containers.running.where("image LIKE ?", "%postgres%").exists?
  end

  # Returns the effective owner of this project for capacity/settings lookups.
  # Falls back to the account's fallback owner (first owner by ID, or
  # first user by ID) when the creating user has been deleted.
  # Uses Account#fallback_owner for deterministic, shared resolution.
  def effective_owner
    created_by || account.fallback_owner
  end

  def trusted_github_user?(login)
    return false if login.blank?

    allowed_github_usernames.any? { |allowed| allowed.downcase == login.downcase }
  end

  def increment_metrics!(cost_cents:, tokens_used:)
    with_lock do
      update!(
        total_cost_cents: total_cost_cents + cost_cents,
        total_tokens_used: total_tokens_used + tokens_used
      )
    end
  end

  def touch_last_agent_run_at(timestamp = Time.current)
    update_column(:last_agent_run_at, timestamp)
  end

  def touch_last_github_activity_at(timestamp = Time.current)
    update_column(:last_github_activity_at, timestamp)
  end

  def touch_last_polled_at(timestamp = Time.current)
    update_column(:last_polled_at, timestamp)
  end

  # Shared staleness threshold used by both the health-check job and the
  # automation health UI. A poll workflow is considered stale when it has not
  # completed a poll cycle within 3× the configured interval plus a buffer.
  STALENESS_BUFFER = 3.minutes

  def poll_staleness_threshold
    (3 * poll_interval_seconds).seconds + STALENESS_BUFFER
  end

  def poll_stale?
    return false unless last_polled_at

    last_polled_at < poll_staleness_threshold.ago
  end

  def broadcast_stats_update
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :stats),
      partial: "projects/stats",
      locals: { project: self }
    )
  end

  def broadcast_agent_runs_update
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :agent_runs),
      partial: "projects/agent_runs",
      locals: { project: self, recent_agent_runs: agent_runs.recent.limit(10) }
    )
  end

  def broadcast_agent_runs_list_update
    broadcast_replace_to(
      self, :agent_runs_list,
      target: ActionView::RecordIdentifier.dom_id(self, :agent_runs_list),
      partial: "agent_runs/table",
      locals: { project: self, agent_runs: agent_runs.recent.includes(:issue).limit(50) }
    )
  end

  def broadcast_agent_run_detail_update(agent_run)
    broadcast_replace_to(
      agent_run, :detail,
      target: ActionView::RecordIdentifier.dom_id(agent_run, :detail),
      partial: "agent_runs/detail",
      locals: { agent_run: agent_run, quality_metrics: agent_run.quality_metrics.with_composite_score.load }
    )
  end

  def broadcast_issues_update
    open_items = issues.where(github_state: "open").order(github_number: :desc)
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :issues),
      partial: "projects/issues",
      locals: { project: self, issues: open_items.issues_only.includes(:sub_issues).limit(25) }
    )
  end

  def broadcast_pull_requests_update
    open_items = issues.where(github_state: "open").order(github_number: :desc)
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :pull_requests),
      partial: "projects/pull_requests",
      locals: {
        project: self,
        pull_requests: open_items.pull_requests_only.limit(25),
        pr_numbers_with_queued_auto_continue: pr_numbers_with_queued_auto_continue,
        pr_numbers_with_active_runs: pr_numbers_with_active_runs
      }
    )
  end

  private

  def auto_pick_just_enabled?
    saved_change_to_auto_pick_enabled? && auto_pick_enabled?
  end

  def trigger_auto_pick
    ProcessRunQueueJob.perform_later
  rescue => e
    Rails.logger.error(message: "auto_pick.trigger_failed", project_id: id, error: e.message)
  end

  def start_github_polling
    return unless active?

    ProjectWorkflowManager.start_polling(self)
  rescue => e
    Rails.logger.error(message: "github_sync.start_polling_failed", project_id: id, error: e.message)
  end

  def stop_github_polling
    ProjectWorkflowManager.stop_polling(self)
  rescue => e
    Rails.logger.error(message: "github_sync.stop_polling_failed", project_id: id, error: e.message)
  end

  def toggle_github_polling
    if active?
      start_github_polling
    else
      stop_github_polling
    end
  end

  def github_token_belongs_to_same_account
    return if github_token.account_id == account_id

    errors.add(:github_token, "must belong to the same account")
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def github_token_is_active
    return if github_token.active?

    errors.add(:github_token, "must be active (not revoked or expired)")
  end

  def owner_reviewer_login_is_trusted
    return if trusted_github_user?(owner_reviewer_login)

    errors.add(:owner_reviewer_login, "must be in trusted GitHub usernames")
  end

  def allowed_github_usernames_not_empty
    return if allowed_github_usernames.is_a?(Array) && allowed_github_usernames.any?(&:present?)

    errors.add(:allowed_github_usernames, "must include at least one trusted GitHub username")
  end
end
