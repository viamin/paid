# frozen_string_literal: true

class Project < ApplicationRecord
  EXTERNAL_ISSUE_TRACKER_LINK_LABELS = {
    "linear" => "Linear Issues",
    "jira" => "Jira",
    "azure_devops" => "Azure DevOps",
    "mcp" => "MCP",
    "generic_webhook" => "Issue Tracker"
  }.freeze
  DEFAULT_ISSUE_TRACKER_URLS = {
    "linear" => "https://linear.app"
  }.freeze
  has_logidze
  MERGE_METHODS = %w[squash merge rebase].freeze
  AUTO_RELEASE_GRANULARITIES = %w[off patch_only minor_only major_only all].freeze
  KNOWLEDGE_STATUSES = %w[pending collecting ready failed stale].freeze
  # "none" is not a method — it is represented by enabled: false at the top level
  REVIEW_METHODS = %w[copilot paid_agent codex ci_action manual].freeze
  SCREENSHOT_DRIVERS = {
    "playwright" => "Best for modern browser flows and JavaScript-heavy apps.",
    "cuprite" => "Best for Rails and other server-rendered apps using Capybara."
  }.freeze

  PRIORITY_TIERS = %w[P1 P2 P3].freeze
  DEFAULT_PRIORITY_LABELS = { "P1" => "P1", "P2" => "P2", "P3" => "P3" }.freeze
  DEFAULT_SCREENSHOT_SETTINGS = {
    "enabled" => false,
    "driver" => "playwright",
    "config_path" => ".paid/screenshots.yml",
    "auto_capture" => true,
    "service_dependencies" => [],
    "setup_commands" => [],
    "detection" => {}
  }.freeze
  DEFAULT_SCREENSHOT_STATUS = {
    "last_capture_at" => nil,
    "last_capture_status" => nil,
    "screenshot_count" => 0,
    "screenshots_url" => nil
  }.freeze

  DEFAULT_REVIEW_SETTINGS = {
    "enabled" => false,
    "wait_for_reviews" => true,
    "address_all_bot_reviews" => false,
    "methods" => {
      "copilot" => {
        "enabled" => false,
        "termination" => {
          "max_review_rounds" => 15,
          "stop_when_no_comments" => true,
          "quality_threshold" => nil,
          "timeout_minutes" => nil
        }
      },
      "paid_agent" => {
        "enabled" => false,
        "termination" => {
          "max_review_rounds" => 15,
          "max_review_goal_retries" => 3,
          "stop_when_no_comments" => true,
          "quality_threshold" => nil,
          "timeout_minutes" => 30
        }
      },
      "codex" => {
        "enabled" => false,
        "termination" => {
          "max_review_rounds" => 15,
          "stop_when_no_comments" => true,
          "quality_threshold" => nil,
          "timeout_minutes" => 60
        }
      },
      "ci_action" => {
        "enabled" => false,
        "action_name" => nil,
        "termination" => {
          "max_review_rounds" => nil,
          "stop_when_no_comments" => true,
          "quality_threshold" => nil,
          "timeout_minutes" => nil
        }
      },
      "manual" => {
        "enabled" => false,
        "reviewer_login" => nil,
        "termination" => {
          "max_review_rounds" => nil,
          "stop_when_no_comments" => false,
          "quality_threshold" => nil,
          "timeout_minutes" => 1440
        }
      }
    }
  }.freeze

  DEFAULT_QUALITY_GATE_SETTINGS = {
    "enabled" => false,
    "composite_score_threshold" => 0.5,
    "min_recent_runs" => 3,
    "lookback_window_hours" => 24,
    "metric_thresholds" => {}
  }.freeze

  AUTOMATION_SETTINGS = [
    { label: "Auto-Add Labels", attribute: :auto_add_labels_enabled,
     description: "Automatically add the generated label to PRs and issues created by Paid." }.freeze,
    { label: "Automation on Label", attribute: :automation_on_label_enabled,
     description: "Automatically create agent runs when the automation label is detected on issues or PRs." }.freeze,
    { label: "Auto-Pick Issues", attribute: :auto_pick_enabled,
     description: "Automatically start working on unblocked issues when no agent runs are active." }.freeze,
    { label: "Auto-Fix Merge Conflicts", attribute: :auto_fix_merge_conflicts,
     description: "Automatically start a PR follow-up run when a paid-ready PR develops merge conflicts against the base branch." }.freeze,
    { label: "Aggregate PRs", attribute: :pr_aggregation_enabled,
     description: "When a feature is decomposed into sub-tasks, aggregate all agent changes into a single PR instead of individual PRs per sub-task." }.freeze,
    { label: "Inherit Priority Labels", attribute: :inherit_priority_labels,
     description: "When Paid creates a PR for an issue, copy any user-defined priority labels (P1/P2/P3) from the issue onto the new PR." }.freeze,
    { label: "Auto-enhance before PR", attribute: :auto_enhance_enabled,
     description: "Analyze issue context readiness before auto-pick creates a PR run" }.freeze,
    { label: "Knowledge evolution", attribute: :knowledge_evolution_enabled,
     description: "Weekly analysis of knowledge gaps and collector effectiveness" }.freeze
  ].freeze

  AUTO_MERGE_MODE_OPTIONS = [
    [ "Off", "off" ],
    [ "Dependabot Only", "dependabot_only" ],
    [ "All PRs", "all" ]
  ].freeze

  AUTO_RELEASE_GRANULARITY_OPTIONS = [
    [ "Off", "off" ],
    [ "Patch only", "patch_only" ],
    [ "Minor and below", "minor_only" ],
    [ "Major and below", "major_only" ],
    [ "All", "all" ]
  ].freeze

  include TenantScoped
  include AutoPickSkipLabels

  belongs_to :github_token, counter_cache: true, optional: true
  belongs_to :github_installation, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user
  has_many :issues, dependent: :destroy
  has_many :agent_runs, dependent: :destroy
  has_many :container_pool_entries, dependent: :destroy
  has_many :worktrees, dependent: :destroy
  has_many :cost_budgets, dependent: :destroy
  has_many :project_baselines, dependent: :destroy
  has_many :agent_run_anomalies, dependent: :destroy
  has_many :quality_recovery_actions, dependent: :destroy
  has_many :token_usages, through: :agent_runs
  has_many :workflow_states, dependent: :destroy
  has_many :prompts, dependent: :destroy
  has_many :strategies, dependent: :destroy
  has_many :style_guides, dependent: :destroy
  has_many :project_versions, dependent: :destroy
  has_many :knowledge_artifacts, dependent: :destroy
  has_many :knowledge_chunks, through: :knowledge_artifacts
  has_many :project_service_containers, dependent: :destroy
  has_many :service_containers, through: :project_service_containers
  has_many :decision_records, dependent: :destroy
  has_many :orchestration_decisions, dependent: :destroy
  has_many :scaling_observations, dependent: :destroy
  has_many :scaling_experiments, dependent: :destroy
  has_many :scaling_experiment_assignments, dependent: :destroy
  has_many :llm_output_metrics, dependent: :destroy
  has_many :knowledge_runs, dependent: :destroy
  has_many :knowledge_usage_stats, dependent: :destroy
  has_many :project_mcp_servers, dependent: :destroy
  has_many :mcp_server_definitions, through: :project_mcp_servers
  has_many :pre_commit_requirements, dependent: :destroy
  has_many :quality_gate_thresholds, dependent: :destroy
  has_many :quality_gate_events, dependent: :destroy
  has_many :quality_thresholds, dependent: :destroy
  has_many :pr_templates, dependent: :destroy
  has_many :chat_session_projects, dependent: :destroy
  has_many :chat_sessions, through: :chat_session_projects
  has_many :context_intake_sessions, dependent: :destroy
  has_one :tracker_configuration, as: :configurable, dependent: :destroy
  has_many :quality_pause_events, dependent: :destroy
  has_many :knowledge_recommendations, dependent: :destroy
  has_many :project_convention_detections, dependent: :destroy
  has_many :project_convention_overrides, dependent: :destroy
  has_many :project_convention_recommendations, dependent: :destroy
  has_many :exception_incidents, dependent: :nullify
  has_many :configuration_bundles, dependent: :destroy
  has_many :coordination_policies, dependent: :destroy

  encrypts :webhook_secret

  before_validation :normalize_priority_labels
  after_update_commit :invalidate_relationship_parsing_on_trust_change

  validates :name, presence: true
  validates :owner, presence: true
  validates :repo, presence: true
  validates :github_id, presence: true, uniqueness: { scope: :account_id }
  validates :poll_interval_seconds, numericality: { greater_than_or_equal_to: 60 }
  validates :max_pr_followup_runs, numericality: { greater_than_or_equal_to: 0 }
  validates :merge_method, inclusion: { in: MERGE_METHODS }
  validates :auto_merge_mode, inclusion: { in: %w[off dependabot_only all] }
  validates :auto_release_granularity, inclusion: { in: AUTO_RELEASE_GRANULARITIES }
  validates :max_draft_review_rounds, numericality: { greater_than_or_equal_to: 0 }
  validates :generated_label_name, presence: true
  validates :automation_label_name, presence: true
  validates :enhance_issue_needs_input_label_name, presence: true
  validates :enhance_issue_enhanced_label_name, presence: true
  validates :max_enhance_issue_reevaluation_rounds,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validates :code_scanning_interval_hours, numericality: { greater_than_or_equal_to: 24 }
  validates :plan_review_timeout_hours,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 720 }
  validates :knowledge_status, inclusion: { in: KNOWLEDGE_STATUSES }
  validates :max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true
  validates :token_limit_warning_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  validates :max_execution_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400 }
  validate :allowed_github_usernames_not_empty
  validate :owner_reviewer_login_is_trusted, if: -> { owner_reviewer_login.present? }
  validate :exactly_one_github_credential
  validate :github_token_belongs_to_same_account, if: -> { github_token.present? }
  validate :github_token_is_active, if: -> { github_token.present? && github_token_id_changed? }
  validate :github_installation_belongs_to_same_account, if: -> { github_installation.present? }
  validate :github_installation_is_active, if: -> { github_installation.present? && github_installation_id_changed? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }
  validate :review_settings_valid
  validate :screenshot_settings_valid
  validate :priority_labels_valid

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  def self.ransackable_attributes(auth_object = nil)
    %w[name last_agent_run_at last_github_activity_at created_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[]
  end

  after_create_commit :start_github_polling
  after_create_commit :enqueue_knowledge_collection
  after_update_commit :toggle_github_polling, if: :saved_change_to_active?
  after_update_commit :clear_scheduler_pause_on_token_change, if: :saved_change_to_github_token_id?
  after_update_commit :clear_scheduler_pause_on_installation_change, if: :saved_change_to_github_installation_id?
  after_update_commit :seed_eligible_issues, if: :auto_pick_just_enabled?
  after_destroy_commit :stop_github_polling
  after_destroy_commit :cleanup_qdrant_collection

  def full_name
    "#{owner}/#{repo}"
  end

  def flipper_id
    "Project;#{id}"
  end

  def github_url
    "https://github.com/#{full_name}"
  end

  def header_external_links(tracker_configuration:)
    links = [ { label: repository_link_label(tracker_configuration), url: github_url } ]
    issue_tracker_link = external_issue_tracker_link(tracker_configuration)
    issue_tracker_link ? links << issue_tracker_link : links
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

  def external_issue_tracker_link(tracker_configuration)
    return if tracker_configuration.blank? || tracker_configuration.tracker_type == "github_issues"

    url = normalized_external_url(
      tracker_configuration.base_url.presence || DEFAULT_ISSUE_TRACKER_URLS[tracker_configuration.tracker_type]
    )
    return if url.blank?

    {
      label: EXTERNAL_ISSUE_TRACKER_LINK_LABELS.fetch(tracker_configuration.tracker_type, "Issue Tracker"),
      url: url
    }
  end

  def repository_link_label(tracker_configuration)
    tracker_configuration&.tracker_type == "github_issues" ? "GitHub" : "GitHub Repo"
  end

  def normalized_external_url(url)
    return if url.blank?

    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTPS)

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
  private :external_issue_tracker_link, :repository_link_label, :normalized_external_url

  def set_label_for_stage(stage, label)
    self.label_mappings = label_mappings.merge(stage.to_s => label)
  end

  # Returns the user-configured GitHub label name for a priority tier ("P1"/"P2"/"P3").
  def priority_label_for(tier)
    effective_priority_labels[tier.to_s]
  end

  def effective_priority_labels
    overrides = (priority_labels || {}).slice(*PRIORITY_TIERS)
      .reject { |_, v| v.nil? || (v.is_a?(String) && v.strip.empty?) }
    DEFAULT_PRIORITY_LABELS.merge(overrides)
  end

  def effective_auto_pick_skip_labels
    return auto_pick_skip_labels unless auto_pick_skip_labels.nil?

    owner_labels = effective_owner&.user_setting&.auto_pick_skip_labels
    return owner_labels unless owner_labels.nil?

    tenant_labels = account&.tenant_setting&.auto_pick_skip_labels
    return tenant_labels unless tenant_labels.nil?

    AutoPickSkipLabels::DEFAULTS
  end

  # All configured priority label names, used by queue ordering and PR inheritance.
  def priority_label_names
    effective_priority_labels.values_at(*PRIORITY_TIERS).compact
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

  # Returns the set of PR numbers that have unclaimed queued automatic agent runs,
  # used by both the controller and Turbo broadcasts to drive the "Bump Priority" UI.
  # Excludes claimed runs (temporal_workflow_id set) since those are already being
  # processed and should not be reprioritized.
  def pr_numbers_with_queued_auto_continue
    agent_runs
      .where(trigger_type: "automatic", status: "queued", temporal_workflow_id: nil)
      .where.not(source_pull_request_number: nil)
      .distinct
      .pluck(:source_pull_request_number)
      .to_set
  end

  # Returns the set of PR numbers that have any unfinished (queued/pending/running/paused) agent run,
  # used to suppress "Quick Run" when a run is already in progress (unique index would reject it).
  def pr_numbers_with_active_runs
    agent_runs
      .where(status: AgentRun::UNFINISHED_STATUSES)
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

  def knowledge_embedding_provider_configuration
    Knowledge::RunnerConfiguration.for_embedding(project: self)
  end

  # Returns true when at least one configured embedding provider can be
  # resolved by the proxy-backed provider selection flow.
  def semantic_search_available?
    Knowledge::RunnerConfiguration.for_embedding_candidate_runners(project: self).present?
  end

  def trusted_github_user?(login)
    return false if login.blank?

    allowed_github_usernames.any? { |allowed| allowed.downcase == login.downcase }
  end

  # Returns the effective token limit per agent run at the project/account level.
  # Resolution: project override → account default.
  # NOTE: For full resolution (including user settings and global default),
  # use AgentRun#effective_max_tokens_per_run instead.
  def project_level_max_tokens_per_run
    account.tenant_max_tokens_per_run(max_tokens_per_run || account.default_max_tokens_per_run)
  end

  # Returns the absolute token count at which a warning should be emitted.
  def token_limit_warning_at
    (project_level_max_tokens_per_run * token_limit_warning_threshold / 100.0).floor
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
    WorkflowState.record_polling_status(self, status: "running")
  end

  def touch_last_issue_sync_at(timestamp = Time.current)
    update_column(:last_issue_sync_at, timestamp)
  end

  def effective_screenshot_settings
    return @effective_screenshot_settings if defined?(@effective_screenshot_settings) && @effective_screenshot_settings

    stored = screenshot_settings.is_a?(Hash) ? screenshot_settings.deep_stringify_keys : {}
    @effective_screenshot_settings = normalize_screenshot_settings(DEFAULT_SCREENSHOT_SETTINGS.deep_merge(stored))
  end

  def effective_screenshot_status
    stored = screenshot_status.is_a?(Hash) ? screenshot_status.deep_stringify_keys : {}
    status = DEFAULT_SCREENSHOT_STATUS.merge(stored)
    status["screenshot_count"] = status["screenshot_count"].to_i
    status
  end

  def screenshot_preview_config(repo_config: {}, settings: nil)
    repo = repo_config.deep_stringify_keys
    settings = normalize_screenshot_settings(settings || effective_screenshot_settings)

    compact_screenshot_hash(
      "driver" => settings["driver"] || repo["driver"],
      "auto_capture" => settings["auto_capture"],
      "services" => settings["service_dependencies"].presence || repo["services"],
      "setup" => settings["setup_commands"].presence || repo["setup"]
    )
  end

  def screenshot_config_conflicts(repo_config:)
    repo = repo_config.deep_stringify_keys
    settings = effective_screenshot_settings
    conflicts = []

    compare_screenshot_setting(conflicts, "driver", settings["driver"], repo["driver"])
    compare_screenshot_setting(conflicts, "auto_capture", settings["auto_capture"], repo["auto_capture"])
    compare_screenshot_setting(conflicts, "services", settings["service_dependencies"], repo["services"])
    compare_screenshot_setting(conflicts, "setup", settings["setup_commands"], repo["setup"])

    conflicts
  end

  def screenshot_enabled?
    effective_screenshot_settings["enabled"]
  end

  # Shared staleness window used by both the health-check job and the
  # automation health UI. A poll workflow is considered stale when it has not
  # recorded forward progress within 3× the configured interval plus a buffer.
  STALENESS_BUFFER = 3.minutes

  def poll_staleness_window
    (3 * poll_interval_seconds).seconds + STALENESS_BUFFER
  end

  def poll_stale?
    return false unless last_polled_at

    last_polled_at < poll_staleness_window.ago
  end

  # Double-checks staleness after a reload to avoid false positives from
  # a race with a just-completed poll cycle. Used by both the automation
  # health UI and the PollWorkflowHealthCheckJob.
  def poll_stale_with_recheck?
    return false unless poll_stale?

    reload
    poll_stale?
  end

  def broadcast_stats_update
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :stats),
      partial: "projects/stats",
      locals: { project: self, budgets: cost_budgets.load }
    )
  end

  def broadcast_cost_snapshot_update
    Projects::StatsSummary.bust_cache!(id)
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :cost_snapshot),
      partial: "projects/cost_snapshot",
      locals: {
        project: self,
        summary: Projects::StatsSummary.call(project: self)
      }
    )
  end

  def broadcast_agent_runs_update
    runs = agent_runs.recent.includes(:runner, :issue, project: [ :created_by, :account ]).limit(10).to_a
    AgentRun.preload_final_runner_records(runs)
    AgentRun.preload_source_pull_requests(runs)
    AgentRun.preload_created_issue_records(runs)
    broadcast_replace_to(
      self, :project_updates,
      target: ActionView::RecordIdentifier.dom_id(self, :agent_runs),
      partial: "projects/agent_runs",
      locals: { project: self, recent_agent_runs: runs }
    )
  end

  def broadcast_agent_runs_list_update
    runs = agent_runs.recent.includes(:runner, :issue, project: [ :created_by, :account ]).limit(50).to_a
    AgentRun.preload_final_runner_records(runs)
    AgentRun.preload_source_pull_requests(runs)
    AgentRun.preload_created_issue_records(runs)
    broadcast_replace_to(
      self, :agent_runs_list,
      target: ActionView::RecordIdentifier.dom_id(self, :agent_runs_list),
      partial: "agent_runs/table",
      locals: { project: self, agent_runs: runs }
    )
  end

  def broadcast_agent_run_detail_update(agent_run)
    final_runner_record = agent_run.final_runner_record
    attempted_runners = agent_run.attempted_runners_by_routing_key

    broadcast_replace_to(
      agent_run, :detail,
      target: ActionView::RecordIdentifier.dom_id(agent_run, :detail),
      partial: "agent_runs/detail",
      locals: {
        agent_run: agent_run,
        quality_metrics: agent_run.quality_metrics.with_composite_score.load,
        final_runner_record: final_runner_record,
        attempted_runners_by_routing_key: attempted_runners
      }
    )
  rescue ActiveRecord::StatementInvalid => error
    # During db:migrate, AgentRun callbacks can still render the detail partial
    # before marketplace attachment tables exist. Ignore only that transient case.
    raise unless missing_agent_run_marketplace_entries_table?(error)
  end

  def self.suppress_broadcasts
    previous = Thread.current[:paid_suppress_project_broadcasts]
    Thread.current[:paid_suppress_project_broadcasts] = true
    yield
  ensure
    Thread.current[:paid_suppress_project_broadcasts] = previous
  end

  def self.broadcasts_suppressed?
    Thread.current[:paid_suppress_project_broadcasts] == true
  end

  def broadcast_issues_update
    return if self.class.broadcasts_suppressed?

    # The project show page renders issue/PR sections from current_user
    # settings and other per-user state, so a shared server-rendered partial
    # broadcast can desynchronize viewers. Refresh lets each client re-render
    # with its own settings.
    broadcast_project_show_refresh
  end

  def broadcast_workflow_status_update
    health = WorkflowState.compute_health_for(self)
    return unless health

    broadcast_replace_to(
      self, :project_updates,
      target: "workflow-status",
      partial: "workflow_statuses/status",
      locals: { project: self, health: health, show_restart: true }
    )
  end

  def broadcast_pull_requests_update
    return if self.class.broadcasts_suppressed?

    broadcast_project_show_refresh
  end

  def auto_release_enabled?
    auto_release_granularity != "off"
  end

  def broadcast_project_show_refresh
    broadcast_refresh_to(self, :project_updates)
  end

  def auto_release_allows_bump?(bump_type)
    case auto_release_granularity
    when "off" then false
    when "all" then true
    when "major_only" then %w[major minor patch].include?(bump_type.to_s)
    when "minor_only" then %w[minor patch].include?(bump_type.to_s)
    when "patch_only" then bump_type.to_s == "patch"
    else false
    end
  end

  def auto_merge_enabled?
    auto_merge_mode != "off"
  end

  def auto_merge_dependabot?
    auto_merge_mode.in?(%w[dependabot_only all])
  end

  def effective_quality_gate_settings
    saved = quality_gate_settings
    saved = saved.is_a?(Hash) ? saved.deep_stringify_keys : {}
    DEFAULT_QUALITY_GATE_SETTINGS.deep_merge(saved)
  end

  def quality_gates_enabled?
    effective_quality_gate_settings["enabled"] == true
  end

  def screenshot_settings=(value)
    @effective_screenshot_settings = nil
    super
  end

  def screenshot_enabled
    effective_screenshot_settings["enabled"] == true
  end

  def screenshot_enabled=(value)
    write_screenshot_setting("enabled", ActiveModel::Type::Boolean.new.cast(value))
  end

  def screenshots_enabled?
    screenshot_enabled
  end

  def screenshot_driver
    effective_screenshot_settings["driver"]
  end

  def screenshot_driver=(value)
    write_screenshot_setting("driver", value)
  end

  def review_settings=(value)
    @effective_review_settings = nil
    @automation_configuration = nil
    super
  end

  def effective_review_settings
    return @effective_review_settings if defined?(@effective_review_settings) && @effective_review_settings

    rs = review_settings
    rs = rs.is_a?(Hash) ? rs : {}
    rs = rs.deep_stringify_keys if rs.respond_to?(:deep_stringify_keys)

    @effective_review_settings = DEFAULT_REVIEW_SETTINGS.deep_merge(rs)
  end

  # Returns the {Automation::Configuration::Project} value object describing
  # this project's normalized automation/review configuration. Strategy
  # code and activities should read through this rather than calling the
  # individual +review_*+ / +auto_*+ helpers so new providers and toggles
  # can be added in one place. Memoized per-instance; invalidated by
  # {#review_settings=} and by {#reload_automation_configuration}.
  def automation_configuration
    @automation_configuration ||= Automation::Configuration::Project.from(self)
  end

  # Forces a rebuild of the memoized {#automation_configuration}. Used by
  # callers that mutate +auto_*+ columns (e.g. toggle actions) without
  # going through {#review_settings=}.
  def reload_automation_configuration
    @automation_configuration = nil
    automation_configuration
  end

  def review_enabled?
    automation_configuration.auto_review.enabled?
  end

  def wait_for_reviews?
    automation_configuration.auto_review.wait_for_reviews?
  end

  def address_all_bot_reviews?
    automation_configuration.auto_review.address_all_bot_reviews?
  end

  def review_method_enabled?(method)
    automation_configuration.auto_review.method_enabled?(method)
  end

  def enabled_review_methods
    automation_configuration.auto_review.ordered_enabled_methods.map { |m| m.name.to_s }
  end

  # Returns the {Automation::Configuration::ReviewMethod} value object for
  # +method+, or nil when the name is not a known review method. Prefer
  # this over {#review_method_config} when you need typed accessors
  # (termination limits, action_name, reviewer_login).
  def review_method(method)
    automation_configuration.auto_review.method_for(method)
  end

  # Returns the set of bot GitHub logins (downcased) for all enabled review
  # methods that have a known bot account (copilot, codex, etc.), plus the
  # project's author-bot identity if using GitHub App auth.
  def enabled_review_bot_logins
    logins = RunnerSupport::RUNNER_BOT_USERNAMES
      .slice(*enabled_review_methods)
      .values.flatten.map(&:downcase).to_set

    logins.merge(author_bot_logins)
  end

  def review_method_config(method)
    effective_review_settings.dig("methods", method.to_s) || {}
  end

  # Returns the GitHub login Paid should request to trigger a review-bot
  # review on a PR, or nil if no automated review method is enabled. Copilot
  # takes precedence when multiple bots are enabled; codex is used when
  # copilot is disabled because it does not auto-review draft PRs and
  # requires an explicit @-mention (see RequestReviewActivity).
  #
  # Returns nil when reviews are globally disabled via
  # review_settings["enabled"], even if an individual method sub-flag is
  # left enabled. Without this guard, RequestReviewActivity's nil-reviewers
  # fallback (driven by AgentExecutionWorkflow after every agent run)
  # would request bot reviews on projects that have opted out of review.
  def review_bot_request_login
    automation_configuration.auto_review.bot_request_login
  end

  # Returns the ordered list of bot-backed reviewer logins to attempt when
  # requesting an automated review, with the primary provider first. Used
  # by RequestReviewActivity to fall back to a secondary bot when the
  # primary is unavailable (e.g. Copilot rate-limited). Returns +[]+ when
  # reviews are globally disabled or no bot-backed method is enabled.
  def review_bot_request_chain
    automation_configuration.auto_review.bot_request_chain
  end

  def scheduler_paused?
    scheduler_paused_at.present?
  end

  def scheduler_pause!(reason:)
    with_lock do
      return false if scheduler_paused?

      update!(
        scheduler_paused_at: Time.current,
        scheduler_pause_reason: reason
      )
    end

    true
  end

  def scheduler_resume!
    with_lock do
      return false unless scheduler_paused?

      update!(
        scheduler_paused_at: nil,
        scheduler_pause_reason: nil
      )
    end

    true
  end

  # Returns an opaque GitHub credential (installation token or PAT) for
  # repo operations. Callers use this without knowing which auth path
  # is active.
  def github_credential
    if github_installation_id.present? || github_installation.present?
      Github::AppInstallation.token_for(
        installation_id: github_installation.github_installation_id,
        repo_full_name: full_name
      )
    else
      github_token&.token
    end
  end

  # Returns a GithubClient authenticated via the project's GitHub credential
  # (installation token for app-backed projects, PAT for token-backed projects).
  def client
    @client ||= GithubClient.new(token: github_credential)
  end

  # Returns true when the project has a configured GitHub credential (PAT or
  # App installation).  Callers that guard on +project.github_token.present?+
  # should use this instead so app-backed projects are not skipped.
  def github_credential_present?
    github_token_id.present? || github_installation_id.present?
  end

  # Returns the GitHub login that will appear as the PR author for
  # commits/PRs created with this project's credentials.
  # For app-backed projects, returns the bot login (e.g. "paid-agents[bot]").
  # For PAT-backed projects, returns nil (author identity is the PAT owner).
  def github_author_login
    if github_installation_id.present? || github_installation.present?
      Github::AppRegistry.bot_login
    end
  end

  # Returns bot logins for the project's configured GitHub App identity,
  # used by reviewer-bot matching in scan_paid_prs_activity.
  def author_bot_logins
    return Set.new unless github_installation_id.present? || github_installation.present?

    Github::AppRegistry.bot_logins.map(&:downcase).to_set
  end

  def quality_paused?
    quality_paused_at.present?
  end

  # Returns the configured quality pause threshold (0.0–1.0), or nil if
  # automatic quality pausing is not configured. Reads from the top-level
  # review_settings key "quality_pause_threshold".
  def quality_pause_threshold
    effective_review_settings["quality_pause_threshold"]&.to_f
  end

  def quality_pause!(score:, threshold:, agent_run: nil, metadata: {})
    with_lock do
      return false if quality_paused?

      now = Time.current
      pause_meta = {
        triggered_at: now.iso8601,
        composite_score: score,
        threshold: threshold
      }.merge(metadata)

      update!(
        quality_paused_at: now,
        quality_pause_metadata: pause_meta
      )

      quality_pause_events.create!(
        event_type: "paused",
        agent_run: agent_run,
        composite_score: score,
        threshold: threshold,
        metadata: pause_meta
      )
    end

    true
  end

  def quality_resume!(metadata: {})
    with_lock do
      return false unless quality_paused?

      resume_meta = {
        resumed_at: Time.current.iso8601,
        was_paused_at: quality_paused_at&.iso8601
      }.merge(metadata)

      update!(
        quality_paused_at: nil,
        quality_pause_metadata: {}
      )

      quality_pause_events.create!(
        event_type: "resumed",
        metadata: resume_meta
      )
    end

    true
  end

  private

  def missing_agent_run_marketplace_entries_table?(error)
    return false unless error.message.include?("agent_run_marketplace_entries")

    defined?(PG::UndefinedTable) && error.cause.is_a?(PG::UndefinedTable)
  end

  def normalize_screenshot_settings(settings)
    settings = settings.to_unsafe_h if settings.respond_to?(:to_unsafe_h)
    settings = settings.to_h if settings.respond_to?(:to_h)
    settings = settings.deep_stringify_keys
    settings["enabled"] = ActiveModel::Type::Boolean.new.cast(settings["enabled"])
    settings["auto_capture"] = ActiveModel::Type::Boolean.new.cast(settings["auto_capture"])
    settings["driver"] = normalized_screenshot_driver(settings["driver"])
    settings["config_path"] = settings["config_path"].presence || DEFAULT_SCREENSHOT_SETTINGS["config_path"]
    settings["service_dependencies"] = normalize_string_array(settings["service_dependencies"])
    settings["setup_commands"] = normalize_string_array(settings["setup_commands"])
    settings["detection"] = settings["detection"].is_a?(Hash) ? settings["detection"].deep_stringify_keys : {}
    settings
  end

  def normalized_screenshot_driver(value)
    value = value.to_s
    SCREENSHOT_DRIVERS.key?(value) ? value : DEFAULT_SCREENSHOT_SETTINGS["driver"]
  end

  def normalize_string_array(value)
    Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def compact_screenshot_hash(hash)
    hash.compact
  end

  def compare_screenshot_setting(conflicts, key, project_value, repo_value)
    return if repo_value.nil? || repo_value == project_value

    conflicts << {
      "key" => key,
      "project_value" => project_value,
      "repo_value" => repo_value
    }
  end

  def clear_scheduler_pause_on_token_change
    return unless scheduler_paused?

    scheduler_resume!
    Rails.logger.info(
      message: "github_token.auto_resume",
      project_id: id,
      new_github_token_id: github_token_id
    )
  end

  def clear_scheduler_pause_on_installation_change
    return unless scheduler_paused?

    scheduler_resume!
    Rails.logger.info(
      message: "github_installation.auto_resume",
      project_id: id,
      new_github_installation_id: github_installation_id
    )
  end

  def auto_pick_just_enabled?
    saved_change_to_auto_pick_enabled? && auto_pick_enabled?
  end

  def seed_eligible_issues
    return unless Issues::AutoPickProjectGate.call(self)

    Issues::BulkEnqueueEligible.call(project: self, skip_project_gate: true)
  rescue => e
    Rails.logger.error(message: "auto_pick.bulk_seed_failed", project_id: id, error: e.message)
  end

  def enqueue_knowledge_collection
    EnqueueKnowledgeCollectionJob.perform_later(id)
  rescue => e
    Rails.logger.error(message: "knowledge.enqueue_collection_failed", project_id: id, error: e.message)
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

  def cleanup_qdrant_collection
    QdrantCollectionCleanupJob.perform_later(id, account_id)
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

  def github_installation_belongs_to_same_account
    return if github_installation.account_id == account_id

    errors.add(:github_installation, "must belong to the same account")
  end

  def github_installation_is_active
    return if github_installation.active?

    errors.add(:github_installation, "must be active (not suspended or revoked)")
  end

  def exactly_one_github_credential
    has_token = github_token_id.present?
    has_installation = github_installation_id.present?

    errors.add(:base, "must have either a GitHub App installation or a PAT, not both") if has_token && has_installation
    errors.add(:base, "must have a GitHub App installation or a PAT") unless has_token || has_installation
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

  # Strip surrounding whitespace from each priority label value before
  # validation/persistence so a label entered as " critical " matches the
  # GitHub label "critical" instead of silently failing tier detection.
  def normalize_priority_labels
    return unless priority_labels.is_a?(Hash)

    self.priority_labels = priority_labels.each_with_object({}) do |(k, v), h|
      h[k] = v.is_a?(String) ? v.strip : v
    end
  end

  def priority_labels_valid
    return if priority_labels.nil? || priority_labels == {}

    unless priority_labels.is_a?(Hash)
      errors.add(:priority_labels, "must be a JSON object")
      return
    end

    PRIORITY_TIERS.each do |tier|
      value = priority_labels[tier]
      next if value.nil?
      unless value.is_a?(String) && value.strip.present?
        errors.add(:priority_labels, "#{tier} label must be a non-blank string")
      end
    end

    extras = priority_labels.keys - PRIORITY_TIERS
    if extras.any?
      errors.add(:priority_labels, "may only contain keys #{PRIORITY_TIERS.join(', ')} (got: #{extras.join(', ')})")
    end
  end

  def review_settings_valid
    return if review_settings.nil? || review_settings == {}

    unless review_settings.is_a?(Hash)
      errors.add(:review_settings, "must be a JSON object")
      return
    end

    # Normalize to string keys so validation works regardless of how the hash was constructed
    normalized = review_settings.deep_stringify_keys

    if normalized["enabled"] == true
      methods = normalized["methods"]
      unless methods.is_a?(Hash) && methods.any? { |_, c| c.is_a?(Hash) && c["enabled"] == true }
        errors.add(:review_settings, "must have at least one review method enabled when reviews are enabled")
      end
    end

    validate_review_methods_config(normalized)
  end

  def screenshot_settings_valid
    return if screenshot_settings.nil? || screenshot_settings == {}

    unless screenshot_settings.is_a?(Hash)
      errors.add(:screenshot_settings, "must be a JSON object")
      return
    end

    normalized = screenshot_settings.deep_stringify_keys

    Screenshots::ConfigParser.validate_partial!(normalized)
  rescue Screenshots::ConfigError => e
    errors.add(:screenshot_settings, e.message)
  end

  def validate_review_methods_config(normalized)
    methods = normalized["methods"]
    return if methods.nil?

    unless methods.is_a?(Hash)
      errors.add(:review_settings, "methods must be a JSON object")
      return
    end

    methods.each do |method_name, config|
      unless REVIEW_METHODS.include?(method_name)
        errors.add(:review_settings, "contains unknown review method: #{method_name}")
        next
      end

      unless config.is_a?(Hash)
        errors.add(:review_settings, "#{method_name} config must be a JSON object")
        next
      end

      next unless config["enabled"] == true

      # ci_action requires an action_name so the system knows which GitHub Action to invoke
      if method_name == "ci_action" && config["action_name"].blank?
        errors.add(:review_settings, "ci_action requires a non-blank action_name when enabled")
      end

      # manual requires a reviewer_login so the system knows who to request review from
      if method_name == "manual" && config["reviewer_login"].blank?
        errors.add(:review_settings, "manual requires a non-blank reviewer_login when enabled")
      end

      if method_name == "paid_agent" && !Github::ReviewBotInstallationToken.configured?
        # Distinguish "no credential set" from "credential set but malformed"
        # so a user who just configured the key isn't sent in circles. The
        # most common cause of the second case is pasting an OpenSSH-format
        # key when the GitHub App needs PKCS#1/PKCS#8 PEM.
        reason =
          if Github::ReviewBotInstallationToken.private_key.present?
            "paid-code-reviewer GitHub App private key is present but cannot be parsed as RSA " \
              "(must be a PEM-encoded PKCS#1 or PKCS#8 key, not OpenSSH format)"
          else
            "paid-code-reviewer GitHub App credentials are not configured"
          end
        errors.add(:review_settings, "paid_agent requires the #{reason}")
      end

      termination = config["termination"]
      if termination.present? && !termination.is_a?(Hash)
        errors.add(:review_settings, "#{method_name} termination must be a JSON object")
        next
      end

      # Validate against the effective (defaults-merged) termination config so
      # partial overrides behave the same way as runtime review_method_config.
      default_termination = DEFAULT_REVIEW_SETTINGS.dig("methods", method_name, "termination") || {}
      effective_termination = default_termination.deep_merge(termination || {})
      validate_termination_config(method_name, effective_termination, explicit_termination: termination || {})
    end
  end

  def validate_termination_config(method_name, termination, explicit_termination: {})
    return unless termination.is_a?(Hash)

    rounds = termination["max_review_rounds"]
    if rounds.present? && (!rounds.is_a?(Integer) || rounds < 1)
      errors.add(:review_settings, "#{method_name} max_review_rounds must be a positive integer")
    end

    if method_name == "paid_agent"
      retries = termination["max_review_goal_retries"]
      if retries.present? && (!retries.is_a?(Integer) || retries < 1)
        errors.add(:review_settings, "#{method_name} max_review_goal_retries must be a positive integer")
      end

      explicit_retries = explicit_termination["max_review_goal_retries"]
      if explicit_retries.is_a?(Integer) && explicit_retries >= 1 &&
          rounds.is_a?(Integer) && rounds >= 1 && retries > rounds
        errors.add(:review_settings, "#{method_name} max_review_goal_retries (#{retries}) must not exceed max_review_rounds (#{rounds})")
      end
    end

    timeout = termination["timeout_minutes"]
    if timeout.present? && (!timeout.is_a?(Integer) || timeout < 1)
      errors.add(:review_settings, "#{method_name} timeout_minutes must be a positive integer")
    end

    paid_agent_retry_condition = method_name == "paid_agent" && termination["max_review_goal_retries"].present?
    has_any_condition = termination["max_review_rounds"].present? ||
                        paid_agent_retry_condition ||
                        termination["stop_when_no_comments"] == true ||
                        termination["quality_threshold"].present? ||
                        termination["timeout_minutes"].present?
    return if has_any_condition

    errors.add(:review_settings, "#{method_name} must have at least one termination condition configured")
  end

  def write_screenshot_setting(key, value)
    settings = screenshot_settings.is_a?(Hash) ? screenshot_settings.deep_stringify_keys : {}
    self.screenshot_settings = settings.merge(key => value)
  end

  def allowed_github_usernames_not_empty
    return if allowed_github_usernames.is_a?(Array) && allowed_github_usernames.any?(&:present?)

    errors.add(:allowed_github_usernames, "must include at least one trusted GitHub username")
  end

  # When the trusted-user list changes, previously-parsed dependency and
  # parent/child relationships may reference content that is now untrusted
  # (or newly visible). Clear relationships_parsed_at so the next sync
  # re-parses every issue under the new trust policy.
  def invalidate_relationship_parsing_on_trust_change
    return unless saved_change_to_allowed_github_usernames?

    issues.update_all(relationships_parsed_at: nil)
  end
end
