# frozen_string_literal: true

class Project < ApplicationRecord
  include PreferredDockerHostIdentifierValidation

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
  PAID_AGENT_REVIEW_BOT_ALLOWLIST_LOGINS = %w[paid-code-reviewer[bot]].freeze
  GITHUB_AUTH_SOURCES = %w[app pat].freeze
  SCREENSHOT_DRIVERS = {
    "playwright" => "Best for modern browser flows and JavaScript-heavy apps.",
    "cuprite" => "Best for Rails and other server-rendered apps using Capybara."
  }.freeze

  LID_MODES = %w[full scoped].freeze
  PRIORITY_TIERS = %w[P1 P2 P3].freeze
  DEFAULT_PRIORITY_LABELS = { "P1" => "P1", "P2" => "P2", "P3" => "P3" }.freeze
  ADOPTION_MODES = %w[observe_only advisory review_only full_execution].freeze
  DATA_CLASSIFICATIONS = %w[open internal confidential restricted].freeze
  DEFAULT_SCREENSHOT_SETTINGS = {
    "enabled" => false,
    "driver" => "playwright",
    "config_path" => ".paid/screenshots.yml",
    "auto_capture" => true,
    "record_video" => false,
    "service_dependencies" => [],
    "setup_commands" => [],
    "detection" => {},
    "verification_enabled" => false
  }.freeze
  PLAYWRIGHT_MCP_NAME = "paid-system-playwright-browser".freeze
  PLAYWRIGHT_MCP_COMMAND = "@executeautomation/playwright-mcp-server".freeze
  PLAYWRIGHT_MCP_BROWSER_HOST = "paid-screenshot-browser".freeze
  PLAYWRIGHT_MCP_CDP_URL = "ws://#{PLAYWRIGHT_MCP_BROWSER_HOST}:3000".freeze
  PLAYWRIGHT_MCP_METADATA = {
    "paid_system" => "playwright_verification_browser"
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
  def self.default_interop_settings
    @default_interop_settings ||= {
      "adoption_mode" => "observe_only",
      "tool_integrations" => Interop::Catalog.tool_integration_keys.index_with(false),
      "connectors" => Interop::Catalog.connector_keys.index_with(false),
      "external_execution_sources" => Interop::Catalog.external_execution_source_keys.index_with(false),
      "imports" => Interop::Catalog.import_keys.index_with { [] }
    }.freeze
  end

  # Valid LLM provider identifiers usable in a project's allowlist/blocklist.
  # These are the upstream LLM services a model can run on (e.g. "anthropic",
  # "openai", "google"), drawn from the API service-type catalog.
  def self.supported_llm_provider_keys
    ProviderSupport::API_SERVICE_TYPES.keys.freeze
  end

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

  # Bots whose PRs may be admitted by scoped automation paths when the project
  # is configured to auto-merge dependency updates. They are deliberately not
  # added to #trusted_github_author_logins because that global author trust also
  # controls issue sync, auto-pick, and prompt-building eligibility.
  DEPENDENCY_UPDATE_BOT_AUTHORS = %w[
    dependabot[bot]
    dependabot-preview[bot]
    renovate[bot]
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
  # Optional PAT used as the git push/fetch credential for app-backed projects
  # when the App installation can't perform the push (e.g. lacks the workflows
  # permission). Distinct from +github_token+ — it is never the project's
  # primary credential and is exempt from +exactly_one_github_credential+.
  belongs_to :git_push_fallback_token, class_name: "GithubToken", optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user
  has_many :issues, dependent: :destroy
  has_many :agent_runs, dependent: :destroy
  has_many :preview_sessions, dependent: :destroy
  has_many :container_pool_entries, dependent: :destroy
  has_many :worktrees, dependent: :destroy
  has_many :cost_budgets, dependent: :destroy
  has_many :roi_benchmarks, dependent: :destroy
  has_many :project_baselines, dependent: :destroy
  has_many :agent_run_anomalies, dependent: :destroy
  has_many :quality_recovery_actions, dependent: :destroy
  has_many :token_usages, through: :agent_runs
  has_many :workflow_states, dependent: :destroy
  has_many :prompts, dependent: :destroy
  has_many :strategies, dependent: :destroy
  has_many :style_guides, dependent: :destroy
  has_many :style_guide_ab_tests, through: :account
  has_many :project_versions, dependent: :destroy
  has_many :knowledge_artifacts, dependent: :destroy
  has_many :knowledge_chunks, through: :knowledge_artifacts
  has_many :project_service_containers, dependent: :destroy
  has_many :service_containers, through: :project_service_containers
  has_many :decision_records, dependent: :destroy
  has_many :change_intents, dependent: :destroy
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
  has_many :context_intake_questions, dependent: :destroy
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
  has_many :external_connector_events, dependent: :destroy

  encrypts :webhook_secret

  before_validation :normalize_priority_labels
  before_validation :normalize_interop_settings
  before_validation :normalize_llm_provider_routing
  before_validation :ensure_paid_reviewer_bot_allowlisted
  before_validation :reset_git_push_pat_fallback_unless_app_backed
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
  validates :lid_mode, inclusion: { in: LID_MODES }, allow_nil: true
  validates :max_draft_review_rounds, numericality: { greater_than_or_equal_to: 0 }
  validates :generated_label_name, presence: true
  validates :automation_label_name, presence: true
  validates :enhance_issue_needs_input_label_name, presence: true
  validates :enhance_issue_enhanced_label_name, presence: true
  validates :max_enhance_issue_reevaluation_rounds,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_issue_runner_failures,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1000 },
    allow_nil: true

  validates :code_scanning_interval_hours, numericality: { greater_than_or_equal_to: 24 }
  validates :plan_review_timeout_hours,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 720 }
  validates :knowledge_status, inclusion: { in: KNOWLEDGE_STATUSES }
  validates :max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true
  validates :max_pr_auto_continue_tokens,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 }
  validates :token_budget_max_input_tokens,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 },
    allow_nil: true
  validates :token_limit_warning_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  validates :max_execution_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400 }
  validates :data_classification, inclusion: { in: DATA_CLASSIFICATIONS }
  validate :allowed_github_usernames_not_empty
  validate :owner_reviewer_login_is_trusted, if: -> { owner_reviewer_login.present? }
  validate :exactly_one_github_credential, if: :validate_github_credential_presence?
  validate :github_token_belongs_to_same_account, if: -> { github_token.present? }
  validate :github_token_is_active, if: -> { github_token.present? && github_token_id_changed? }
  validate :github_installation_belongs_to_same_account, if: -> { github_installation.present? }
  validate :github_installation_is_active, if: -> { github_installation.present? && github_installation_id_changed? }
  validate :git_push_fallback_token_valid, if: -> { git_push_fallback_token_id.present? }
  validate :git_push_pat_fallback_requires_token, if: -> { git_push_pat_fallback_enabled? }
  validate :created_by_belongs_to_same_account, if: -> { created_by.present? }
  validate :review_settings_valid
  validate :screenshot_settings_valid
  validate :verification_mcp_definition_name_available, if: :verification_will_be_enabled?
  validate :priority_labels_valid
  validate :interop_settings_valid
  validate :llm_provider_routing_valid
  validate :validate_preferred_docker_host_identifier

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
  after_update_commit :cancel_queued_auto_pick_runs, if: :auto_pick_just_disabled?
  after_update_commit :ensure_playwright_mcp_definition!, if: :verification_just_enabled?
  after_destroy_commit :stop_github_polling
  after_destroy_commit :cleanup_qdrant_collection

  def full_name
    "#{owner}/#{repo}"
  end

  # Normalized primary language key (downcased) used by the prompt-building
  # services (e.g. Prompts::LanguageCommands) to select test/lint commands.
  # Returns nil when no language has been detected for the repository.
  def detected_language
    primary_language&.strip&.downcase&.presence
  end

  # Human-friendly project-type label (e.g. "Ruby on Rails") shown as a badge
  # on project tiles. Returns nil when no language has been detected.
  def project_type_label
    framework_label = detected_framework_label
    return framework_label if framework_label.present? && detected_framework != "generic"

    return if primary_language.blank?

    Projects::LanguageProfile.label_for(primary_language) || primary_language
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

  def confidential?
    data_classification == "confidential"
  end

  def restricted?
    data_classification == "restricted"
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

  # Whether +login+ is a trusted collaborator or opted-in review bot on this project. Use
  # this for inputs that are an untrusted prompt-injection channel —
  # issue/PR/review COMMENTS — so only operator-allowlisted authors reach the
  # agent. Deliberately does NOT implicitly include the GitHub App bot: Paid must not
  # feed its own bot's comments back into the agent. Compare with
  # #trusted_github_author?, which is broader and covers issue/PR authorship.
  def trusted_github_user?(login)
    return false if login.blank?

    allowed_github_usernames.any? { |allowed| allowed.downcase == login.downcase }
  end

  # Logins trusted as the AUTHOR (creator) of an issue or PR — i.e. trusted
  # for Paid to pick up and work on it. The human allowlist plus, for GitHub
  # App projects, the app's own bot identity (implicit, never stored in
  # allowed_github_usernames), so Paid can act on issues/PRs its own bot
  # opens. Broader than #trusted_github_user? on purpose: author trust controls
  # pickup/queueing, while comment trust stays human-only. Dependency-update
  # bots are admitted by scoped PR-scan authorization instead of this global
  # list. All logins are downcased for case-insensitive comparison.
  #
  # Uses github_author_login (the "[bot]" form, e.g. "paid-agents[bot]"),
  # which is the only login GitHub ever reports as the author of app-created
  # content. Deliberately NOT author_bot_logins, which also includes the bare
  # app slug ("paid-agents") — that is a registerable human GitHub username
  # and must not be granted author trust.
  def trusted_github_author_logins
    logins = Array(allowed_github_usernames).filter_map { |name| name.to_s.downcase.presence }
    bot_author = github_author_login&.downcase
    logins << bot_author if bot_author
    logins.uniq
  end

  def trusted_github_author?(login)
    return false if login.blank?

    trusted_github_author_logins.include?(login.downcase)
  end

  # True when +login+ is this project's own GitHub App bot identity
  # (e.g. "paid-agents[bot]"). Returns false for PAT-backed projects, which
  # have no bot identity. Use ONLY to re-admit Paid's own structured marker
  # comments (enhancement questions, clarifying answers) that Paid authored as
  # the bot — never to trust arbitrary bot comments as human input, which is
  # why #trusted_github_user? deliberately excludes the bot. The bot login is
  # unspoofable: only Paid's GitHub App can author content as it.
  def paid_bot_author?(login)
    return false if login.blank?

    bot_login = github_author_login
    bot_login.present? && login.downcase == bot_login.downcase
  end

  # Returns the effective token limit per agent run at the project/account level.
  # Resolution: project override → account default.
  # NOTE: For full resolution (including user settings and global default),
  # use AgentRun#effective_max_tokens_per_run instead.
  def project_level_max_tokens_per_run
    account.tenant_max_tokens_per_run(max_tokens_per_run || account.default_max_tokens_per_run)
  end

  # Returns the effective per-issue per-provider retry cap for this project.
  # Resolution: project override → account-level agent setting → constant
  # default (Issue::DEFAULT_MAX_RUNNER_FAILURES). After a single provider fails
  # this many times for one issue, it is excluded from scheduling for that issue.
  def effective_max_issue_runner_failures
    return max_issue_runner_failures if max_issue_runner_failures.present?

    account_cap = account&.tenant_setting&.effective_agent_settings&.dig("max_issue_runner_failures")
    return account_cap.to_i if account_cap.present?

    Issue::DEFAULT_MAX_RUNNER_FAILURES
  end

  def effective_preferred_docker_host_identifier
    preferred_docker_host_identifier.presence ||
      account&.tenant_setting&.effective_preferred_docker_host_identifier
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

  def effective_interop_settings
    return @effective_interop_settings if defined?(@effective_interop_settings) && @effective_interop_settings

    stored = interop_settings.is_a?(Hash) ? interop_settings.deep_stringify_keys : {}
    @effective_interop_settings = self.class.default_interop_settings.deep_merge(stored)
  end

  # Per-project LLM provider allowlist/blocklist, stored under
  # +model_preferences["llm_providers"]+ as:
  #   { "allowlist" => [ "anthropic" ], "blocklist" => [] }
  # Only one of allowlist/blocklist may be populated (mutually exclusive).
  # Provider identifiers are upstream LLM services (see supported_llm_provider_keys).
  def llm_provider_routing
    stored = model_preferences.is_a?(Hash) ? model_preferences["llm_providers"] : nil
    stored = stored.is_a?(Hash) ? stored.deep_stringify_keys : {}

    {
      "allowlist" => Array(stored["allowlist"]).map(&:to_s),
      "blocklist" => Array(stored["blocklist"]).map(&:to_s)
    }
  end

  def llm_provider_allowlist
    llm_provider_routing["allowlist"]
  end

  def llm_provider_blocklist
    llm_provider_routing["blocklist"]
  end

  def llm_provider_routing_restricted?
    llm_provider_allowlist.any? || llm_provider_blocklist.any?
  end

  # Active restriction mode: "allowlist", "blocklist", or nil when unrestricted.
  def llm_provider_routing_mode
    return "allowlist" if llm_provider_allowlist.any?
    return "blocklist" if llm_provider_blocklist.any?

    nil
  end

  # True when +provider+ (an upstream LLM service identifier such as
  # "anthropic") is permitted for this project. With no restriction configured
  # every provider is allowed.
  def llm_provider_allowed?(provider)
    return true if provider.blank?
    return true unless llm_provider_routing_restricted?

    key = provider.to_s
    allowlist = llm_provider_allowlist
    return allowlist.include?(key) if allowlist.any?

    !llm_provider_blocklist.include?(key)
  end

  def llm_provider_blocked?(provider)
    !llm_provider_allowed?(provider)
  end

  def adoption_mode
    effective_interop_settings["adoption_mode"]
  end

  def observe_only?
    adoption_mode == "observe_only"
  end

  def advisory?
    adoption_mode == "advisory"
  end

  def review_only?
    adoption_mode == "review_only"
  end

  def full_execution?
    adoption_mode == "full_execution"
  end

  def external_execution_enabled_for?(source_key)
    effective_interop_settings
      .fetch("external_execution_sources", {})
      .fetch(source_key.to_s, false) == true
  end

  def effective_screenshot_status
    stored = screenshot_status.is_a?(Hash) ? screenshot_status.deep_stringify_keys : {}
    status = DEFAULT_SCREENSHOT_STATUS.merge(stored)
    status["screenshot_count"] = status["screenshot_count"].to_i
    status
  end

  def effective_repo_profile
    return @effective_repo_profile if defined?(@effective_repo_profile) && @effective_repo_profile

    @effective_repo_profile = Projects::RepoProfile.normalize(
      repo_profile,
      primary_language: primary_language,
      screenshot_framework: effective_screenshot_settings.dig("detection", "framework")
    )
  end

  def detected_languages
    effective_repo_profile.fetch("languages", [])
  end

  def test_languages
    effective_repo_profile.fetch("test_languages", detected_languages)
  end

  # Framework detected by the screenshot framework detector, surfaced as
  # preview metadata (RDR-045). Returns nil when no detection has run.
  def detected_framework
    effective_repo_profile["framework"]
  end

  def detected_framework_label
    Projects::FrameworkProfile.label_for(detected_framework)
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
    runs = agent_runs.excluding_synthetic.recent.includes(:runner, :issue, project: [ :created_by, :account ]).limit(10).to_a
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
    runs = agent_runs.excluding_synthetic.recent.includes(:runner, :issue, project: [ :created_by, :account ]).limit(50).to_a
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
    return unless agent_run_marketplace_entries_table_exists?

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
  rescue ActiveRecord::StatementInvalid, ActionView::Template::Error => error
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

  def auto_merge_bot_authored?
    allow_bot_authored_pr_auto_merge?
  end

  def effective_quality_gate_settings
    saved = quality_gate_settings
    saved = saved.is_a?(Hash) ? saved.deep_stringify_keys : {}
    DEFAULT_QUALITY_GATE_SETTINGS.deep_merge(saved)
  end

  def quality_gates_enabled?
    effective_quality_gate_settings["enabled"] == true
  end

  def interop_settings=(value)
    @effective_interop_settings = nil
    super
  end

  def reload(*)
    @effective_interop_settings = nil
    @effective_repo_profile = nil
    @effective_screenshot_settings = nil
    @effective_review_settings = nil
    @automation_configuration = nil
    super
  end

  def repo_profile=(value)
    @effective_repo_profile = nil
    super
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

  def verification_enabled
    effective_screenshot_settings["verification_enabled"] == true
  end

  def verification_enabled=(value)
    write_screenshot_setting("verification_enabled", ActiveModel::Type::Boolean.new.cast(value))
  end

  def verification_enabled?
    verification_enabled
  end

  # Ensures the account-scoped playwright-mcp MCP server definition exists and is
  # attached to this project. Idempotent — safe to call on every verification
  # run. Returns the attached definition record.
  #
  # The npx definition is materialized by `Containers::McpProvisioner` at run
  # time. The CDP URL env points at the `paid-screenshot-browser` container
  # that the verification flow provisions on the agent's network. The URL is
  # stable, so it is set at definition time rather than injected per-run.
  def ensure_playwright_mcp_definition!
    definition = account.mcp_server_definitions.find_or_initialize_by(name: PLAYWRIGHT_MCP_NAME)
    if definition.persisted? && !playwright_mcp_definition?(definition)
      raise ArgumentError, "Reserved MCP definition name #{PLAYWRIGHT_MCP_NAME} is already used by a non-Paid definition"
    end

    definition.assign_attributes(
      transport: "stdio",
      install_type: "npx",
      command: PLAYWRIGHT_MCP_COMMAND,
      args: [],
      env: { "CDP_URL" => PLAYWRIGHT_MCP_CDP_URL },
      metadata: normalized_metadata(definition.metadata).merge(PLAYWRIGHT_MCP_METADATA),
      enabled: true
    )
    definition.save! if definition.new_record? || definition.changed?

    project_mcp_servers.find_or_create_by!(mcp_server_definition: definition)
    definition
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

  # @spec FOCUSED-RUN-009
  def ensure_paid_reviewer_bot_allowlisted
    current = Array(allowed_github_usernames).filter_map { |login| login.to_s.presence }
    managed_logins = PAID_AGENT_REVIEW_BOT_ALLOWLIST_LOGINS

    if paid_agent_review_config_enabled?
      current_downcased = current.map(&:downcase)
      additions = managed_logins.reject { |login| current_downcased.include?(login.downcase) }
      self.allowed_github_usernames = current + additions if additions.any?
    else
      pruned = current.reject { |login| managed_logins.any? { |managed| managed.casecmp?(login) } }
      self.allowed_github_usernames = pruned if pruned.size != current.size
    end
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

  def paid_agent_review_config_enabled?
    return false unless review_settings.is_a?(Hash)

    normalized = review_settings.deep_stringify_keys
    normalized["enabled"] == true && normalized.dig("methods", "paid_agent", "enabled") == true
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

  # User-controlled pause toggle. When true, queued automatic runs are held;
  # manual runs are unaffected. In-progress runs continue to completion.
  def pause!
    update!(paused: true)
  end

  def unpause!
    update!(paused: false)
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
  # is active. Memoized per instance so a single request does not
  # re-derive the credential — #client derives it internally too, so
  # callers that touch both (e.g. RepoReadClientResolver) would otherwise
  # fetch the App installation token twice. #installation_token_refresher
  # clears the memo so a 401 mid-request still mints a fresh token.
  # @spec GITHUB-SYNC-003
  def github_credential
    return @github_credential if defined?(@github_credential)

    @github_credential =
      if github_installation_id.present? || github_installation.present?
        credential_active?(github_installation) ? Github::AppInstallation.token_for(
          installation_id: github_installation.github_installation_id,
          repo_full_name: full_name
        ) : nil
      else
        credential_active?(github_token) ? github_token&.token : nil
      end
  end

  # True when this app-backed project is configured to retry a GitHub
  # operation with its fallback PAT after the App installation token is
  # rejected for a missing permission (e.g. a change touching
  # .github/workflows/). This is the opt-in gate only — the App remains the
  # default credential for every operation; the PAT is used solely for the
  # failing retry (see Containers::GitOperations, WorktreeService, and
  # Activities::MergePullRequestActivity for the push and merge retry sites).
  # We trust the configured setting rather than inspecting the PAT's scopes,
  # because fine-grained PATs do not report classic OAuth scopes.
  def git_push_pat_fallback_configured?
    return false unless github_installation_id.present? || github_installation.present?
    return false unless git_push_pat_fallback_enabled?
    return false unless git_push_fallback_token.present?

    credential_active?(git_push_fallback_token)
  end

  # The fallback PAT credential string, or nil when fallback is not configured.
  # Used by the git-level push retry, which swaps the credential in the git
  # remote URL rather than going through a GithubClient.
  def git_push_fallback_credential
    git_push_fallback_token.token if git_push_pat_fallback_configured?
  end

  # The fallback PAT's authenticated GithubClient, or nil when fallback is not
  # configured. Used by REST-API-level retries (e.g. a merge rejected for the
  # same missing App permission) that need a ready client rather than a raw
  # token string.
  def git_push_fallback_client
    git_push_fallback_token.client if git_push_pat_fallback_configured?
  end

  # Returns a GithubClient authenticated via the project's GitHub credential
  # (installation token for app-backed projects, PAT for token-backed projects).
  def client
    @client ||= if github_installation_id.present? || github_installation.present?
      credential = github_credential
      credential.present? ? GithubClient.new(
        token: credential,
        health_endpoint: github_health_endpoint,
        token_refresher: installation_token_refresher
      ) : nil
    else
      github_token&.client
    end
  end

  # Returns a proc that clears the cached App installation token and mints
  # a fresh one. Passed to +GithubClient+ so a 401 mid-request triggers a
  # transparent re-mint instead of a hard failure (RDR-030). Clears the
  # per-instance memo set by #github_credential so the re-mint returns the
  # fresh token rather than the stale memoized value.
  def installation_token_refresher
    return nil unless github_installation_id.present? || github_installation.present?

    installation = github_installation
    repo_name = full_name

    -> {
      Github::AppInstallation.clear_cached_token(
        installation_id: installation.github_installation_id,
        repo_full_name: repo_name
      )
      remove_instance_variable(:@github_credential) if defined?(@github_credential)
      github_credential
    }
  end

  def github_health_endpoint
    if github_installation_id.present? || github_installation.present?
      GithubHealthState.endpoint_for_github_installation(github_installation.github_installation_id)
    elsif github_token_id.present?
      GithubHealthState.endpoint_for_github_token(github_token_id)
    else
      GithubHealthState::DEFAULT_ENDPOINT
    end
  end

  # Returns true when the project has a configured GitHub credential (PAT or
  # App installation).  Callers that guard on +project.github_token.present?+
  # should use this instead so app-backed projects are not skipped.
  def github_credential_present?
    github_token.present? || github_installation.present?
  end

  def github_auth_source
    github_installation.present? ? "app" : "pat"
  end

  def paid_agents_installation(installations: active_github_installations)
    Array(installations).find { |installation| installation.covers_repository?(full_name) }
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

  def agent_run_marketplace_entries_table_exists?
    ActiveRecord::Base.connection.data_source_exists?("agent_run_marketplace_entries")
  rescue ActiveRecord::StatementInvalid
    false
  end

  def active_github_installations
    account.github_installations.active
  end

  def missing_agent_run_marketplace_entries_table?(error)
    causes = []
    current_error = error

    while current_error
      causes << current_error
      current_error = current_error.cause
    end

    causes.any? do |cause|
      cause.message.include?("agent_run_marketplace_entries") &&
        defined?(PG::UndefinedTable) &&
        cause.is_a?(PG::UndefinedTable)
    end
  end

  def normalize_screenshot_settings(settings)
    settings = settings.to_unsafe_h if settings.respond_to?(:to_unsafe_h)
    settings = settings.to_h if settings.respond_to?(:to_h)
    settings = settings.deep_stringify_keys
    settings["enabled"] = ActiveModel::Type::Boolean.new.cast(settings["enabled"])
    settings["auto_capture"] = ActiveModel::Type::Boolean.new.cast(settings["auto_capture"])
    settings["record_video"] = ActiveModel::Type::Boolean.new.cast(settings["record_video"])
    settings["verification_enabled"] = ActiveModel::Type::Boolean.new.cast(settings["verification_enabled"])
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

  def auto_pick_just_disabled?
    saved_change_to_auto_pick_enabled? && !auto_pick_enabled?
  end

  def verification_just_enabled?
    return false unless saved_change_to_screenshot_settings?

    previous, current = saved_change_to_screenshot_settings
    previous_value = previous.is_a?(Hash) ? previous["verification_enabled"] : nil
    current_value = current.is_a?(Hash) ? current["verification_enabled"] : nil
    ActiveModel::Type::Boolean.new.cast(current_value) && !ActiveModel::Type::Boolean.new.cast(previous_value)
  end

  def verification_will_be_enabled?
    verification_enabled? && screenshot_settings_change_to_verification_enabled?
  end

  def screenshot_settings_change_to_verification_enabled?
    return true if new_record?
    return false unless will_save_change_to_screenshot_settings?

    previous_value = effective_screenshot_settings_from(screenshot_settings_in_database)["verification_enabled"]
    ActiveModel::Type::Boolean.new.cast(previous_value) == false
  end

  def verification_mcp_definition_name_available
    definition = account&.mcp_server_definitions&.find_by(name: PLAYWRIGHT_MCP_NAME)
    return if definition.blank? || playwright_mcp_definition?(definition)

    errors.add(:screenshot_settings, "verification cannot use reserved MCP definition #{PLAYWRIGHT_MCP_NAME} because that name is already taken")
  end

  def playwright_mcp_definition?(definition)
    normalized_metadata(definition.metadata).slice(*PLAYWRIGHT_MCP_METADATA.keys) == PLAYWRIGHT_MCP_METADATA
  end

  def normalized_metadata(value)
    metadata = value.is_a?(Hash) ? value : {}
    metadata.deep_stringify_keys
  end

  def effective_screenshot_settings_from(value)
    settings = value.is_a?(Hash) ? value : {}
    settings = settings.deep_stringify_keys if settings.respond_to?(:deep_stringify_keys)
    DEFAULT_SCREENSHOT_SETTINGS.deep_merge(settings)
  end

  def seed_eligible_issues # @spec EAGER-QUEUE-004
    return unless Issues::AutoPickProjectGate.call(self)

    Issues::BulkEnqueueEligible.call(project: self, skip_project_gate: true)
  rescue => e
    Rails.logger.error(message: "auto_pick.bulk_seed_failed", project_id: id, error: e.message)
  end

  # @spec AUTO-PICK-QUEUE-001
  def cancel_queued_auto_pick_runs
    queued_auto_pick_runs = agent_runs
      .where(status: "queued")
      .where("agent_runs.auto_pick = TRUE OR (agent_runs.trigger_type = 'automatic' AND agent_runs.goal = 'enhance_issue')")
      .to_a
    return if queued_auto_pick_runs.empty?

    cancelled_run_ids = queued_auto_pick_runs.filter_map { |run| run.id if cancel_auto_pick_run(run) }
    return if cancelled_run_ids.empty?

    # No manual LiveDashboardBroadcastJob/CacheVersion bump here: cancel_auto_pick_run
    # cancels each run through AgentRun#cancel!, whose after_commit broadcast_project_updates
    # callback already enqueues LiveDashboardBroadcastJob(refresh_queue_preview: true) per run.
    Rails.logger.info(
      message: "auto_pick.queued_runs_cancelled",
      project_id: id,
      cancelled_count: cancelled_run_ids.size
    )
  rescue => e
    Rails.logger.error(message: "auto_pick.queued_runs_cancel_failed", project_id: id, error: e.message)
  end

  # Cancels via AgentRuns::Cancel (not update_all) so that a queued run already
  # claimed by a Temporal workflow (AgentRun.claimed) actually has that
  # workflow and any container torn down, and so the normal AgentRun
  # after_commit broadcasts fire for each run.
  def cancel_auto_pick_run(run)
    AgentRuns::Cancel.call(agent_run: run, error: "Auto-Pick disabled for project")
  rescue => e
    Rails.logger.error(
      message: "auto_pick.queued_run_cancel_failed",
      project_id: id,
      agent_run_id: run.id,
      error: e.message
    )
    false
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

  # Validates the selected fallback token exists and is in this account. Checking
  # by id (not the loaded association) also rejects a non-existent id from a
  # crafted request, which would otherwise pass to a raw foreign-key violation.
  def git_push_fallback_token_valid
    return if git_push_fallback_token&.account_id == account_id

    errors.add(:git_push_fallback_token, "must belong to the same account")
  end

  # Enabling the fallback is meaningless without a PAT to fall back to.
  def git_push_pat_fallback_requires_token
    return if git_push_fallback_token_id.present?

    errors.add(:git_push_fallback_token, "must be selected to enable PAT push fallback")
  end

  # The fallback PAT only makes sense for app-backed projects. Rather than
  # rejecting a project that is switched to PAT auth while a fallback lingers
  # (a dead-end the user can't escape from the PAT settings panel), drop the
  # now-meaningless fallback so the switch saves cleanly.
  def reset_git_push_pat_fallback_unless_app_backed
    return if github_installation_id.present? || github_installation.present?

    self.git_push_pat_fallback_enabled = false
    self.git_push_fallback_token_id = nil
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

  def validate_github_credential_presence?
    persisted? || github_token_id.present? || github_installation_id.present?
  end

  def created_by_belongs_to_same_account
    return if created_by.account_id == account_id

    errors.add(:created_by, "must belong to the same account")
  end

  def github_token_is_active
    return if github_token.active?

    errors.add(:github_token, "must be active (not revoked or expired)")
  end

  def credential_active?(credential)
    return false if credential.nil?
    return credential.active? if credential.respond_to?(:active?)

    true
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

  def interop_settings_valid
    return if interop_settings.nil? || interop_settings == {}

    unless interop_settings.is_a?(Hash)
      errors.add(:interop_settings, "must be a JSON object")
      return
    end

    normalized = interop_settings.deep_stringify_keys

    mode = normalized["adoption_mode"]
    if mode.present? && !ADOPTION_MODES.include?(mode)
      errors.add(:interop_settings, "adoption_mode must be one of: #{ADOPTION_MODES.join(', ')}")
    end

    validate_interop_boolean_map(normalized, "tool_integrations", Interop::Catalog.tool_integration_keys)
    validate_interop_boolean_map(normalized, "connectors", Interop::Catalog.connector_keys)
    validate_interop_boolean_map(normalized, "external_execution_sources", Interop::Catalog.external_execution_source_keys)
    validate_interop_imports(normalized)
  end

  def normalize_interop_settings
    return unless interop_settings.is_a?(Hash)

    normalized = interop_settings.deep_stringify_keys
    @effective_interop_settings = nil

    %w[tool_integrations connectors external_execution_sources].each do |key|
      next unless normalized[key].is_a?(Hash)

      normalized[key] = normalized[key].transform_values do |value|
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end

    self.interop_settings = normalized
  end

  def normalize_llm_provider_routing
    return unless model_preferences.is_a?(Hash)

    normalized = model_preferences.deep_stringify_keys
    raw = normalized["llm_providers"]
    return if raw.nil?
    return unless raw.is_a?(Hash)

    routing = raw.deep_stringify_keys
    routing["allowlist"] = normalize_llm_provider_list(routing["allowlist"]) if routing["allowlist"].is_a?(Array)
    routing["blocklist"] = normalize_llm_provider_list(routing["blocklist"]) if routing["blocklist"].is_a?(Array)
    normalized["llm_providers"] = routing
    self.model_preferences = normalized
  end

  def normalize_llm_provider_list(value)
    value.map { |entry| entry.to_s.strip.downcase }.reject(&:blank?).uniq.sort
  end

  def llm_provider_routing_valid
    return unless model_preferences.is_a?(Hash)

    raw = model_preferences["llm_providers"]
    return if raw.nil?

    unless raw.is_a?(Hash)
      errors.add(:model_preferences, "llm_providers must be a JSON object")
      return
    end

    normalized = raw.deep_stringify_keys
    valid_keys = self.class.supported_llm_provider_keys

    %w[allowlist blocklist].each do |list_name|
      value = normalized[list_name]
      next if value.nil?

      unless value.is_a?(Array)
        errors.add(:model_preferences, "llm_providers.#{list_name} must be an array of provider identifiers")
        next
      end

      entries = value.map { |entry| entry.to_s.strip }.reject(&:blank?)
      unknown = entries - valid_keys
      next if unknown.empty?

      errors.add(:model_preferences, "llm_providers.#{list_name} contains unknown provider: #{unknown.join(', ')}")
    end

    allowlist_set = normalized["allowlist"].is_a?(Array) && normalized["allowlist"].any?
    blocklist_set = normalized["blocklist"].is_a?(Array) && normalized["blocklist"].any?
    return unless allowlist_set && blocklist_set

    errors.add(
      :model_preferences,
      "llm_providers allowlist and blocklist are mutually exclusive \u2014 specify only one"
    )
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

  def validate_interop_boolean_map(normalized, key, allowed_keys)
    value = normalized[key]
    return if value.nil?

    unless value.is_a?(Hash)
      errors.add(:interop_settings, "#{key} must be a JSON object")
      return
    end

    extras = value.keys - allowed_keys
    if extras.any?
      errors.add(:interop_settings, "#{key} contains unknown entries: #{extras.join(', ')}")
    end

    value.each do |child_key, child_value|
      next if child_value == true || child_value == false

      errors.add(:interop_settings, "#{key}.#{child_key} must be true or false")
    end
  end

  def validate_interop_imports(normalized)
    imports = normalized["imports"]
    return if imports.nil?

    unless imports.is_a?(Hash)
      errors.add(:interop_settings, "imports must be a JSON object")
      return
    end

    extras = imports.keys - Interop::Catalog.import_keys - [ "last_import" ]
    if extras.any?
      errors.add(:interop_settings, "imports contains unknown entries: #{extras.join(', ')}")
    end

    imports.each do |key, value|
      next if key == "last_import"

      unless value.is_a?(Array)
        errors.add(:interop_settings, "imports.#{key} must be an array")
        next
      end

      value.each do |entry|
        next if entry.is_a?(Hash)

        errors.add(:interop_settings, "imports.#{key} entries must be JSON objects")
      end
    end
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
