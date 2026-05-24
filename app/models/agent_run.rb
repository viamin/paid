# frozen_string_literal: true

class AgentRun < ApplicationRecord
  attribute :focus, :string, default: "general"
  attr_accessor :preloaded_final_runner_record, :preloaded_final_runner_record_loaded

  MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH = 500
  MAX_PROVIDER_ATTEMPT_ERROR_MESSAGE_LENGTH = MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH
  RUNNER_ATTEMPT_SECRET_PATTERNS = [
    [ /\bsk-[A-Za-z0-9][A-Za-z0-9_-]{10,}\b/, "[REDACTED:api_key]" ],
    [ /\b(?:ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[oushr]_[A-Za-z0-9]{36,})\b/, "[REDACTED:github_token]" ],
    [ %r{x-access-token:[^@/\s]+@github\.com}, "x-access-token:[REDACTED]@github.com" ],
    [ /(Bearer\s)[A-Za-z0-9\-._~+\/]+=*/i, "\\1[REDACTED]" ]
  ].freeze
  STATUSES = %w[queued running paused completed no_output failed cancelled timeout retried auth_expired rate_limited].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot aider gemini opencode kilocode pi api].freeze
  FOCUSES = %w[general ci_fix review_feedback merge_conflict conversation issue_implementation label_action].freeze
  # analyze_issue is automation-only (triggered via Automation::Decision), not exposed in the manual run form.
  GOALS = %w[create_pr create_issue review enhance_issue analyze_issue].freeze
  TRIGGER_TYPES = %w[manual automatic].freeze
  ACTIVE_STATUSES = %w[running].freeze
  FINISHED_STATUSES = %w[completed no_output failed cancelled timeout retried auth_expired rate_limited].freeze
  FAILURE_STATUSES = %w[failed timeout auth_expired rate_limited].freeze
  TERMINAL_FAILURE_STATUSES = (FAILURE_STATUSES + %w[cancelled]).freeze
  QUALITY_EXCLUDED_STATUSES = %w[timeout auth_expired rate_limited].freeze
  STDOUT_TAIL_LINES = 500

  OPERATIONAL_FAILURE_KEYWORDS = [
    "providers exhausted",
    "runners exhausted",
    "Docker exec",
    "Activity task timed out",
    "Activity task failed",
    "Activity canceled",
    "worktree",
    "Worktree path does not exist",
    "Clone failed",
    "Push failed",
    "Fetch failed",
    "Credential proxy",
    "Failed to start service",
    "Failed to start workflow",
    "Failed to open TCP",
    "Failed to resolve remote",
    "Failed to get HEAD SHA",
    "could not obtain a connection from the pool",
    "incompatible character encodings",
    "string contains null byte",
    "is closed; project resync",
    "No container provisioned",
    "commit_uncommitted_changes failed"
  ].freeze
  INFRA_FAILURE_KEYWORDS = [
    "Validation failed:",
    "ProviderAuthExpiredError",
    "Provision::TimeoutError",
    "Provision::StartupTimeoutError",
    "Provision::IdleTimeoutError"
  ].freeze
  PRE_MODEL_FAILURE_STATUSES = %w[failed no_output].freeze

  def self.quality_scoreable_sql
    excluded_status = arel_table[:status].not_in(QUALITY_EXCLUDED_STATUSES)

    error_message = Arel::Nodes::NamedFunction.new(
      "COALESCE",
      [ arel_table[:error_message], Arel::Nodes.build_quoted("") ]
    )

    failed_operational = OPERATIONAL_FAILURE_KEYWORDS.map { |keyword|
      arel_table[:status].eq("failed").and(
        error_message.matches("%#{keyword}%")
      )
    }.reduce(:or)

    tokens_input = Arel::Nodes::NamedFunction.new(
      "COALESCE",
      [ arel_table[:tokens_input], Arel::Nodes.build_quoted(0) ]
    )
    pre_model_status = arel_table[:status].in(PRE_MODEL_FAILURE_STATUSES)
    infra_keyword_match = INFRA_FAILURE_KEYWORDS.map { |keyword|
      error_message.matches("%#{keyword}%")
    }.reduce(:or)

    pre_model_infra = pre_model_status
      .and(tokens_input.eq(0))
      .and(infra_keyword_match)

    arel_table.grouping(
      excluded_status
        .and(Arel::Nodes::Not.new(failed_operational))
        .and(Arel::Nodes::Not.new(pre_model_infra))
    )
  end
  UNFINISHED_STATUSES = %w[queued running paused].freeze
  GUARDRAIL_VIOLATION_TYPES = %w[loop_detected token_limit cost_limit time_limit anomaly].freeze
  AUTO_PICK_BLOCKING_STATUSES = UNFINISHED_STATUSES
  TOKEN_LIMIT_STATUSES = %w[ok warning exceeded].freeze
  DEFAULT_MAX_TOKENS_PER_RUN = 10_000_000
  MAX_STALE_REQUEUES = 2
  MAX_STALE_SKIPS = 3
  CLAIMED_SENTINEL = "claimed"
  SMOKE_TEST_CUSTOM_PROMPT = "smoke_test"
  STALE_CLAIMED_TIMEOUT = 15.minutes
  STALE_PAUSED_TIMEOUT = 2.hours
  STALE_RUNNING_GRACE_PERIOD = 10.minutes
  STALE_RUNNING_HEALTHY_LOOKBACK = 14.days
  STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE = 20
  STALE_RUNNING_HEALTHY_PERCENTILE = 0.95
  STALE_RUNNING_HEALTHY_MULTIPLIER = 3
  STALE_RUNNING_MIN_ACTIVE_TIME = 10.minutes
  STALE_RUNNING_HEALTHY_STATUSES = %w[completed no_output].freeze
  STALE_RUNNING_TIMEOUT_CACHE_KEY = "agent_runs/stale_running_timeouts_by_goal/v1"
  STALE_RUNNING_TIMEOUT_CACHE_TTL = 5.minutes

  # Sentinel prefix written into AgentRun#error_message by `bin/rails dev:cleanup`
  # when it forcibly times out an in-flight run because the host process is being
  # restarted (e.g. `bin/setup --skip-server`). Code that observes a run failing
  # while marked with this prefix should treat the failure as caused by the
  # cleanup, not by the runner — in particular, do not increment runner
  # circuit-breaker counters on its behalf.
  STALE_CLEANUP_ERROR_PREFIX = "Marked stale on startup"

  STALE_DETECTOR_ERROR_PREFIX = "Stale run detected"

  belongs_to :project, counter_cache: true
  belongs_to :issue, optional: true
  belongs_to :prompt_version, optional: true
  belongs_to :provider, -> { with_discarded }, class_name: "Provider", foreign_key: :runner_id, optional: true
  belongs_to :runner, -> { with_discarded }, optional: true
  belongs_to :configuration_bundle, optional: true
  belongs_to :initiating_user, class_name: "User", optional: true

  has_many :agent_run_logs, dependent: :destroy
  has_many :agent_run_phases, -> { order(:started_at, :id) }, dependent: :destroy
  has_many :container_pool_entries, dependent: :nullify
  has_many :token_usages, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy
  has_many :configuration_experiment_assignments, dependent: :destroy
  has_many :bundle_outcomes, dependent: :destroy
  has_many :strategy_experiment_assignments, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all
  has_many :quality_metrics, dependent: :destroy
  has_many :orchestration_decisions, dependent: :nullify
  has_one :worktree, dependent: :nullify
  has_one :model_selection, dependent: :destroy
  has_one :decision_record, dependent: :nullify
  has_many :agent_run_anomalies, dependent: :destroy
  has_many :knowledge_usage_stats, dependent: :destroy
  has_many :agent_run_marketplace_entries, -> { order(:position) }, dependent: :destroy
  has_many :sent_coordination_signals,
    class_name: "AgentCoordinationSignal",
    foreign_key: :source_agent_run_id,
    dependent: :destroy,
    inverse_of: :source_agent_run
  has_many :received_coordination_signals,
    class_name: "AgentCoordinationSignal",
    foreign_key: :target_agent_run_id,
    dependent: :nullify,
    inverse_of: :target_agent_run

  attr_readonly :mcp_server_snapshot

  before_validation :set_initiating_user_from_current_user, on: :create
  before_create :generate_proxy_token
  before_create :snapshot_mcp_servers

  before_update :store_project_counter_cache_state, if: :project_counter_cache_state_changed?
  before_destroy :store_destroyed_project_counter_cache_state

  after_commit :update_completed_agent_runs_counter_cache, on: [ :create, :update, :destroy ]
  after_commit :reload_project_counter_cache_association, on: [ :create, :update, :destroy ]
  after_commit :broadcast_project_updates, on: [ :create, :update ]
  after_commit :update_project_last_agent_run_at, on: :create
  after_commit :invalidate_runner_options_cache_on_change, on: [ :create, :update ]
  after_commit :enqueue_quality_metrics_collection, on: :update, if: :just_finished?
  after_commit :enqueue_anomaly_detection, on: :update, if: :just_finished?
  after_commit :enqueue_container_metrics_collection, on: :update, if: :just_started_running?
  after_commit :enqueue_issue_goal_timeout_retry, on: :update, if: :just_timed_out_issue_goal?
  after_commit :enqueue_failure_recovery_decision, on: :update, if: :recovery_decision_required?

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :goal, presence: true, inclusion: { in: GOALS }
  validates :focus, presence: true, inclusion: { in: FOCUSES }
  validate :review_goal_requires_pull_request
  validate :issue_goal_requires_issue
  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }
  validates :created_issue_url, length: { maximum: 500 }
  validates :worktree_path, length: { maximum: 500 }
  validates :branch_name, length: { maximum: 255 }
  validates :base_commit_sha, length: { maximum: 40 }
  validates :result_commit_sha, length: { maximum: 40 }
  validates :pull_request_url, length: { maximum: 500 }
  validates :review_url, length: { maximum: 500 }
  validates :temporal_workflow_id, length: { maximum: 255 }
  validates :temporal_run_id, length: { maximum: 255 }
  validates :parent_workflow_id, length: { maximum: 255 }
  validates :container_id, length: { maximum: 128 }
  validates :container_host, length: { maximum: 64 }, allow_nil: true
  validates :iterations, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_input, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_output, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source_pull_request_number, numericality: { greater_than: 0 }, allow_nil: true
  validates :expected_draft_review_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :auth_provider, length: { maximum: 50 }
  validates :diagnosis_status, inclusion: { in: %w[in_progress processing completed failed] }, allow_nil: true
  validates :diagnosis_issue_url, length: { maximum: 500 }
  validates :final_runner, length: { maximum: 50 }
  validates :runner_switches, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :stale_requeue_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :stale_skip_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :turns_completed, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :token_limit_status, inclusion: { in: TOKEN_LIMIT_STATUSES }, allow_nil: true
  validates :guardrail_violation_type, inclusion: { in: GUARDRAIL_VIOLATION_TYPES }, allow_nil: true
  validates :priority_tier, inclusion: { in: Project::PRIORITY_TIERS }, allow_nil: true
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :initiating_user_belongs_to_project_account, if: -> { initiating_user.present? && project.present? }
  validate :runner_belongs_to_project_owner, if: -> { runner.present? }
  validate :has_prompt_source, on: :create
  validate :draft_review_round_tracking_is_consistent

  def provider_id
    runner_id
  end

  def provider_id=(value)
    self.runner_id = value
  end

  def provider_switches
    runner_switches
  end

  def provider_switches=(value)
    self.runner_switches = value
  end

  def providers_attempted
    runners_attempted
  end

  def providers_attempted=(value)
    self.runners_attempted = value
  end

  def final_provider
    final_runner
  end

  def final_provider=(value)
    self.final_runner = value
  end

  def provider=(value)
    return self.runner = value if value.is_a?(Runner) || value.nil?

    super
  end

  scope :by_status, ->(status) { where(status: status) }
  scope :queued, -> { where(status: "queued") }
  scope :waiting, -> { queued.where(temporal_workflow_id: nil) }
  scope :claimed, -> { queued.where.not(temporal_workflow_id: nil) }
  scope :unclaimed, -> { waiting }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :no_output, -> { where(status: "no_output") }
  scope :failed, -> { where(status: "failed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :timeout, -> { where(status: "timeout") }
  scope :retried, -> { where(status: "retried") }
  scope :auth_expired, -> { where(status: "auth_expired") }
  scope :paused, -> { where(status: "paused") }
  scope :rate_limited, -> { where(status: "rate_limited") }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :capacity_inflight, -> { running.or(claimed) }
  scope :finished, -> { where(status: FINISHED_STATUSES) }

  def update_columns(attributes)
    super(attributes)
  end

  def settings_user
    initiating_user || project&.effective_owner
  end

  scope :recent, -> { order(created_at: :desc) }
  scope :started_before, ->(time) { where("started_at < ?", time) }
  scope :updated_before, ->(time) { where("updated_at < ?", time) }
  scope :stale_running, -> { running.where(stale_running_condition_sql(now: Time.current)) }
  scope :stale_claimed, -> { claimed.updated_before(stale_claimed_cutoff) }
  scope :stale_for_cleanup, -> { stale_running.or(stale_claimed) }
  scope :search_by_goal, lambda { |query|
    normalized_query = query.to_s.strip

    if normalized_query.present?
      pattern = "%#{sanitize_sql_like(normalized_query)}%"
      where("goal ILIKE :pattern OR custom_prompt ILIKE :pattern", pattern: pattern)
    else
      all
    end
  }

  # Trusted SQL column expressions that may be passed to
  # normalize_runner_sql. Restricting to a whitelist prevents
  # accidental SQL injection if a future caller passes untrusted input.
  NORMALIZABLE_COLUMNS = [
    "agent_type",
    "final_runner",
    "NULLIF(final_runner, '')",
    "attempt->>'runner'"
  ].freeze
  LEGACY_PROVIDER_NORMALIZABLE_COLUMNS = {
    "final_provider" => "final_runner",
    "NULLIF(final_provider, '')" => "NULLIF(final_runner, '')",
    "attempt->>'provider'" => "COALESCE(attempt->>'runner', attempt->>'provider')"
  }.freeze

  # SQL CASE expression that normalizes a column's value to its canonical
  # runner key (e.g. "claude_code" → "claude") so SQL aggregations match
  # Ruby logic.
  #
  # Derived from RunnerSupport.runner_key_for_agent_type for all known
  # AGENT_TYPES so that SQL and Ruby stay in sync if new aliases are added
  # or existing mappings change.
  #
  # +column+ must be one of NORMALIZABLE_COLUMNS to guard against SQL
  # injection. Defaults to "agent_type".
  def self.normalize_runner_sql(column = "agent_type")
    unless NORMALIZABLE_COLUMNS.include?(column)
      raise ArgumentError, "untrusted column #{column.inspect} — add it to NORMALIZABLE_COLUMNS if it is safe"
    end

    build_normalized_runner_sql(column)
  end

  def self.normalize_provider_sql(column = "agent_type")
    normalized_column = LEGACY_PROVIDER_NORMALIZABLE_COLUMNS.fetch(column, column)
    raise ArgumentError, "untrusted column #{column.inspect} — add it to NORMALIZABLE_COLUMNS if it is safe" unless trusted_provider_normalizable_column?(column, normalized_column)

    build_normalized_runner_sql(normalized_column)
  end

  def self.normalized_agent_type_sql
    normalize_runner_sql("agent_type")
  end

  # SQL expression for the effective runner: the runner that actually
  # produced the output. Mirrors the Ruby #effective_runner method so that
  # both SQL aggregations and Ruby code share the same logic.
  def self.effective_runner_sql
    "COALESCE(#{normalize_runner_sql("NULLIF(final_runner, '')")}, #{normalized_agent_type_sql})"
  end

  def self.effective_provider_sql
    "COALESCE(#{normalize_provider_sql("NULLIF(final_provider, '')")}, #{normalized_agent_type_sql})"
  end

  ransacker :tokens_total, type: :integer do
    Arel.sql("COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)")
  end

  ransacker :effective_runner do
    Arel.sql(effective_runner_sql)
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[status agent_type branch_name trigger_type goal duration_seconds tokens_input tokens_output tokens_total cost_cents created_at started_at effective_runner]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[project]
  end

  class << self
    def distinct_effective_provider_options(...)
      distinct_effective_runner_options(...)
    end

    def provider_options_cache_key_for(...)
      runner_options_cache_key_for(...)
    end

    def invalidate_provider_options_cache(...)
      invalidate_runner_options_cache(...)
    end

    def preload_final_provider_records(...)
      preload_final_runner_records(...)
    end
  end

  RUNNER_OPTIONS_CACHE_TTL = 5.minutes

  def self.distinct_effective_runner_options(account_id:, cache_key: nil)
    if cache_key
      Rails.cache.fetch(cache_key, expires_in: RUNNER_OPTIONS_CACHE_TTL) do
        compute_distinct_effective_runner_options(account_id: account_id)
      end
    else
      compute_distinct_effective_runner_options(account_id: account_id)
    end
  end

  def self.runner_options_cache_key_for(account_id:, project_id: nil)
    generation = runner_options_cache_generation_for(account_id: account_id)

    if project_id
      "agent_runs/runners/account/#{account_id}/v#{generation}/project/#{project_id}"
    else
      "agent_runs/runners/account/#{account_id}/v#{generation}"
    end
  end

  def self.invalidate_runner_options_cache(account_id:, project_id: nil)
    keys = [ runner_options_cache_key_for(account_id: account_id) ]
    keys << runner_options_cache_key_for(account_id: account_id, project_id: project_id) if project_id
    keys.each { |key| Rails.cache.delete(key) }

    return if project_id

    invalidate_runner_options_cache_for_account(account_id: account_id)
  end

  def self.preload_final_runner_records(runs)
    runs = runs.to_a
    return runs if runs.empty?

    fallback_owner_ids = fallback_owner_ids_by_account(
      runs.filter_map { |run| run.project&.account_id if run.project&.created_by_id.nil? }.uniq
    )
    records_by_lookup = final_runner_records_by_lookup(runs, fallback_owner_ids)

    runs.each do |run|
      final_identifier = run.final_runner.presence
      next if final_identifier.blank?

      run.preloaded_final_runner_record_loaded = true
      run.preloaded_final_runner_record =
        if run.runner.present? && run.runner.matches_identifier?(final_identifier)
          run.runner
        else
          owner_id = effective_owner_id_for(run, fallback_owner_ids)
          records_by_lookup[[ owner_id, final_identifier ]]
        end
    end

    runs
  end

  def self.compute_distinct_effective_runner_options(account_id:)
    identifiers = pluck(Arel.sql("DISTINCT #{effective_runner_sql}")).compact
    routed_options = routed_runner_filter_options_by_identifier(identifiers, account_id:)

    identifiers
      .filter_map do |identifier|
        if Runner.routing_key?(identifier)
          routed_options[identifier]
        else
          Runner.filter_option_for_identifier(identifier, account_id: account_id)
        end
      end
      .uniq
      .sort_by { |option| [ option[:label], option[:value] ] }
  end
  private_class_method :compute_distinct_effective_runner_options

  def self.runner_options_cache_generation_for(account_id:)
    Rails.cache.read(runner_options_cache_generation_key_for(account_id: account_id)) || 1
  end
  private_class_method :runner_options_cache_generation_for

  def self.runner_options_cache_generation_key_for(account_id:)
    "agent_runs/runners/account/#{account_id}/generation"
  end
  private_class_method :runner_options_cache_generation_key_for

  def self.invalidate_runner_options_cache_for_account(account_id:)
    prefix = /\Aagent_runs\/runners\/account\/#{account_id}(?:\/|\z)/
    Rails.cache.delete_matched(prefix)
  rescue NotImplementedError
    generation_key = runner_options_cache_generation_key_for(account_id: account_id)
    current_generation = runner_options_cache_generation_for(account_id: account_id)
    Rails.cache.write(generation_key, current_generation + 1)
  end
  private_class_method :invalidate_runner_options_cache_for_account

  def self.routed_runner_filter_options_by_identifier(identifiers, account_id:)
    runner_ids_by_identifier = identifiers.each_with_object({}) do |identifier, memo|
      runner_id = Runner.id_from_routing_key(identifier)
      memo[identifier] = runner_id if runner_id
    end
    return {} if runner_ids_by_identifier.empty?

    runners_by_id = Runner.with_discarded.joins(:user)
      .where(id: runner_ids_by_identifier.values.uniq, users: { account_id: account_id })
      .index_by(&:id)

    runner_ids_by_identifier.each_with_object({}) do |(identifier, runner_id), memo|
      runner = runners_by_id[runner_id]
      next unless runner

      memo[identifier] = {
        label: runner.display_name,
        value: identifier
      }
    end
  end
  private_class_method :routed_runner_filter_options_by_identifier

  def self.final_runner_records_by_lookup(runs, fallback_owner_ids)
    lookup_pairs = runs.filter_map do |run|
      final_identifier = run.final_runner.presence
      next unless Runner.routing_key?(final_identifier)

      owner_id = effective_owner_id_for(run, fallback_owner_ids)
      next unless owner_id

      [ owner_id, final_identifier ]
    end.uniq
    return {} if lookup_pairs.empty?

    runner_ids = lookup_pairs.map { |(_, identifier)| Runner.id_from_routing_key(identifier) }.uniq
    owner_ids = lookup_pairs.map(&:first).uniq

    Runner.with_discarded.where(id: runner_ids, user_id: owner_ids).index_by { |runner| [ runner.user_id, runner.routing_key ] }
  end
  private_class_method :final_runner_records_by_lookup

  def self.build_normalized_runner_sql(column)
    remapped = AGENT_TYPES.filter_map do |agent_type|
      runner_key = RunnerSupport.runner_key_for_agent_type(agent_type)
      next if runner_key == agent_type

      "WHEN #{quote_sql_literal(agent_type)} THEN #{quote_sql_literal(runner_key)}"
    end

    return column if remapped.empty?

    "CASE #{column} #{remapped.join(" ")} ELSE #{column} END"
  end
  private_class_method :build_normalized_runner_sql

  def self.trusted_provider_normalizable_column?(original_column, normalized_column)
    LEGACY_PROVIDER_NORMALIZABLE_COLUMNS.key?(original_column) || NORMALIZABLE_COLUMNS.include?(normalized_column)
  end
  private_class_method :trusted_provider_normalizable_column?

  def self.quote_sql_literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end
  private_class_method :quote_sql_literal

  def self.effective_owner_id_for(run, fallback_owner_ids)
    project = run.project
    return unless project

    project.created_by_id || fallback_owner_ids[project.account_id]
  end
  private_class_method :effective_owner_id_for

  def self.fallback_owner_ids_by_account(account_ids)
    account_ids = account_ids.compact.uniq
    return {} if account_ids.empty?

    owner_ids = AccountMembership.where(account_id: account_ids, role: :owner)
      .order(:account_id, :id)
      .pluck(:account_id, :user_id)
      .each_with_object({}) { |(account_id, user_id), memo| memo[account_id] ||= user_id }

    missing_account_ids = account_ids - owner_ids.keys
    return owner_ids if missing_account_ids.empty?

    User.where(account_id: missing_account_ids)
      .order(:account_id, :id)
      .pluck(:account_id, :id)
      .each { |account_id, user_id| owner_ids[account_id] ||= user_id }

    owner_ids
  end
  private_class_method :fallback_owner_ids_by_account

  def duration
    return nil unless started_at

    end_time = completed_at || Time.current
    [ (end_time - started_at).to_i, 0 ].max
  end

  # Checks whether the given user has capacity for another agent run.
  #
  # Capacity is determined by the user's max_concurrent_runs setting capped by
  # the account tenant guardrail when one is configured.
  # Returns false (fail closed) when no user is provided, so orphaned
  # projects or unresolvable owners cannot bypass concurrency limits.
  def self.has_run_capacity?(user: nil)
    return false unless user

    active_count_for_user(user) < user.account.tenant_max_concurrent_runs(user.settings.max_concurrent_runs)
  end

  # Returns the count of active runs attributable to the given user.
  # Counts runs on projects the user created. Also counts runs on
  # orphaned projects (created_by_id IS NULL) in the user's account,
  # but only when the user is the account's effective fallback owner
  # (matching Project#effective_owner's resolution chain).
  def self.active_count_for_user(user)
    scope = capacity_inflight.joins(:project).where(projects: { created_by_id: user.id })

    if orphaned_project_owner?(user)
      scope = scope.or(
        capacity_inflight.joins(:project).where(
          projects: { created_by_id: nil, account_id: user.account_id }
        )
      )
    end

    scope.count
  end

  # Returns the count of active runs for a given project.
  def self.active_count_for_project(project)
    capacity_inflight.where(project_id: project.id).count
  end

  def self.stale_running_timeout(goal: nil)
    return default_stale_running_timeout if goal.blank?

    stale_running_timeouts_by_goal.fetch(goal.to_s, default_stale_running_timeout)
  end

  def self.stale_claimed_timeout
    STALE_CLAIMED_TIMEOUT
  end

  def self.stale_paused_timeout
    STALE_PAUSED_TIMEOUT
  end

  def self.stale_running_cutoff(goal: nil, now: Time.current)
    now - stale_running_timeout(goal: goal)
  end

  def self.stale_claimed_cutoff(now: Time.current)
    now - stale_claimed_timeout
  end

  def self.stale_paused_cutoff(now: Time.current)
    now - stale_paused_timeout
  end

  # Returns true if this user is the fallback owner for orphaned
  # projects in their account. Delegates to Account#fallback_owner_id
  # for shared, deterministic resolution matching Project#effective_owner.
  def self.orphaned_project_owner?(user)
    user.account.fallback_owner_id == user.id
  end

  def self.stale_running?(agent_run, now: Time.current)
    agent_run.status == "running" &&
      agent_run.started_at.present? &&
      agent_run.started_at < stale_running_cutoff(goal: agent_run.goal, now: now)
  end

  def self.default_stale_running_timeout
    AGENT_TIMEOUT_DEFAULT.seconds + STALE_RUNNING_GRACE_PERIOD
  end

  def self.stale_running_timeouts_by_goal
    return build_stale_running_timeouts_by_goal if Rails.env.test?

    Rails.cache.fetch(STALE_RUNNING_TIMEOUT_CACHE_KEY, expires_in: STALE_RUNNING_TIMEOUT_CACHE_TTL) do
      build_stale_running_timeouts_by_goal
    end
  end

  def self.stale_running_condition_sql(now: Time.current)
    default_timeout = default_stale_running_timeout
    cutoffs_by_goal = stale_running_cutoffs_by_goal(now: now,
      timeouts_by_goal: stale_running_timeouts_by_goal,
      default_timeout: default_timeout)
    goal_column = %("#{table_name}"."goal")
    started_at_column = %("#{table_name}"."started_at")

    known_goal_clauses = GOALS.map do |goal|
      sanitize_sql_array([
        "(#{goal_column} = ? AND #{started_at_column} < ?)",
        goal,
        cutoffs_by_goal.fetch(goal)
      ])
    end

    known_goals_sql = GOALS.map { |goal| sanitize_sql_array([ "?", goal ]) }.join(", ")
    fallback_clause = sanitize_sql_array([
      "((#{goal_column} IS NULL OR #{goal_column} NOT IN (#{known_goals_sql})) AND #{started_at_column} < ?)",
      now - default_timeout
    ])

    "(#{(known_goal_clauses << fallback_clause).join(' OR ')})"
  end

  def self.healthy_successful_runtime_stats_by_goal
    TenantContext.with_system_access do
      where(status: STALE_RUNNING_HEALTHY_STATUSES)
        .where(goal: GOALS, completed_at: STALE_RUNNING_HEALTHY_LOOKBACK.ago..Time.current)
        .where.not(duration_seconds: nil)
        .group(:goal)
        .pluck(
          :goal,
          Arel.sql("COUNT(*)"),
          Arel.sql("percentile_cont(#{STALE_RUNNING_HEALTHY_PERCENTILE}) WITHIN GROUP (ORDER BY duration_seconds)")
        )
        .to_h do |goal, count, p95|
          [ goal, { count: count.to_i, p95: p95.to_f } ]
        end
    end
  end

  def self.build_stale_running_timeouts_by_goal
    healthy_runtime_stats = healthy_successful_runtime_stats_by_goal

    GOALS.index_with do |goal|
      adaptive_stale_running_timeout(healthy_runtime_stats[goal])
    end
  end

  def self.stale_running_cutoffs_by_goal(now:, timeouts_by_goal:, default_timeout:)
    GOALS.index_with do |goal|
      now - timeouts_by_goal.fetch(goal, default_timeout)
    end
  end

  def self.adaptive_stale_running_timeout(stats)
    return default_stale_running_timeout unless healthy_runtime_stats?(stats)

    adaptive_active_time = [
      (stats[:p95] * STALE_RUNNING_HEALTHY_MULTIPLIER).ceil,
      STALE_RUNNING_MIN_ACTIVE_TIME
    ].max

    [ adaptive_active_time + STALE_RUNNING_GRACE_PERIOD, default_stale_running_timeout ].min
  end

  def self.healthy_runtime_stats?(stats)
    stats.present? &&
      stats[:count] >= STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE &&
      stats[:p95].positive?
  end
  # Priority ordering for the run queue (6 tiers):
  #   0 = manual runs (user pre-emption — highest)
  #   1 = P1 user-defined label
  #   2 = P2 user-defined label
  #   3 = automatic runs fixing a PR (auto-continue, no priority label)
  #   4 = P3 user-defined label
  #   5 = automatic runs from auto-pick (lowest)
  #
  # Within each tier, runs continuing work on an existing PR
  # (source_pull_request_number IS NOT NULL) sort ahead of fresh runs.
  # This is enforced via IN_PROGRESS_SQL in QUEUE_ORDER, not by adding
  # tiers to the CASE expression, so the user-facing tier badges remain
  # the same.
  #
  # Priority is strict within a single project. Across projects QUEUE_ORDER
  # sorts by per-project in-flight count first, so a flood of P1s in one
  # project cannot fully starve another project's lower-priority work.
  #
  # User-defined priority labels (configured per project via
  # Project#priority_labels) are read from either the run's associated
  # issue OR the source pull request (looked up by source_pull_request_number
  # against the project's issues table). If multiple priority labels are
  # present, the highest takes precedence (P1 > P2 > P3).
  #
  # Issue labels in SQL are resolved once via a LATERAL join to avoid
  # repeated correlated subqueries per priority tier.
  #
  # Within each tier, create_issue runs are prioritized over create_pr
  # runs because issue creation is lighter-weight and often unblocks
  # downstream PR work. Within each goal type, runs are FIFO by
  # created_at, with id as a stable tiebreaker.
  QUEUE_PRIORITIES = {
    manual: { label: "Manual", indicator: 1 },
    label_p1: { label: "P1", indicator: 2 },
    label_p2: { label: "P2", indicator: 3 },
    auto_continue: { label: "Auto-continue", indicator: 4 },
    label_p3: { label: "P3", indicator: 5 },
    auto_pick: { label: "Auto-pick", indicator: 6 }
  }.freeze
  UNKNOWN_PRIORITY = { label: "Unknown", indicator: nil }.freeze

  def queue_priority_tier
    return :manual if manual?

    label_tier = label_priority_tier
    case label_tier
    when "P1" then :label_p1
    when "P2" then :label_p2
    when "P3" then :label_p3
    else
      automatic? && existing_pr? ? :auto_continue : :auto_pick
    end
  end

  # Returns "P1"/"P2"/"P3" if the run's issue or source PR carries one of
  # the project's configured priority labels (highest wins), else nil.
  # Memoized because rendering helpers call this twice per row (once
  # via queue_priority_tier and once via queue_priority_label).
  #
  # NOTE: The memoization is per-instance and is only safe for the
  # request-scoped rendering use case. Long-running processes that hold
  # onto an AgentRun across an issue.labels update will see a stale tier;
  # call AgentRun#reload (or instantiate a new record) in those cases.
  def label_priority_tier
    return @label_priority_tier if defined?(@label_priority_tier)
    @label_priority_tier = compute_label_priority_tier
  end

  # When a run has both an associated issue AND a source PR, labels from
  # both records are considered (highest configured tier wins). Label
  # name matching is case-insensitive on both the Ruby and SQL sides, so
  # an issue tagged "p1" still matches a configured tier of "P1".
  def compute_label_priority_tier
    return nil unless project

    label_sources = []
    label_sources << issue.labels if issue&.labels.present?
    pr_record = source_pull_request_record
    label_sources << pr_record.labels if pr_record&.labels.present?
    return nil if label_sources.empty?

    Project::PRIORITY_TIERS.find do |tier|
      label_name = project.priority_label_for(tier)
      next false if label_name.blank?
      label_sources.any? { |labels| labels.any? { |label| label.casecmp?(label_name) } }
    end
  end
  private :compute_label_priority_tier

  attr_writer :source_pull_request_record, :created_issue_record

  # The Issue row representing this run's source pull request, used by
  # label_priority_tier. Falls back to a per-row find_by, but callers
  # rendering many runs should call AgentRun.preload_source_pull_requests
  # first to avoid an N+1.
  def source_pull_request_record
    return @source_pull_request_record if defined?(@source_pull_request_record)
    return nil if source_pull_request_number.blank? || project.nil?

    @source_pull_request_record = project.issues.find_by(
      github_number: source_pull_request_number, is_pull_request: true
    )
  end

  # Batch-loads source PR Issue rows for a collection of runs and stashes
  # each on the run via source_pull_request_record=. Call from controllers
  # rendering priority badges for many runs to keep label_priority_tier
  # from issuing one query per row. Groups by project_id so the query is
  # precise per project (no cross-project over-fetch) without resorting
  # to dynamic SQL.
  def self.preload_source_pull_requests(runs)
    targets = Array(runs).select do |r|
      r.source_pull_request_number.present? && r.project_id.present? &&
        !r.instance_variable_defined?(:@source_pull_request_record)
    end
    return if targets.empty?

    records = {}
    targets.group_by(&:project_id).each do |project_id, group|
      numbers = group.map(&:source_pull_request_number).uniq
      Issue.where(is_pull_request: true, project_id: project_id, github_number: numbers).each do |issue|
        records[[ issue.project_id, issue.github_number ]] = issue
      end
    end

    targets.each do |run|
      run.source_pull_request_record = records[[ run.project_id, run.source_pull_request_number ]]
    end
  end

  # The Issue row representing this run's created issue, used for tooltip
  # display. Falls back to a per-row find_by, but callers rendering many
  # runs should call AgentRun.preload_created_issue_records first to
  # avoid an N+1.
  def created_issue_record
    return @created_issue_record if defined?(@created_issue_record)
    return nil if created_issue_number.blank? || project.nil?

    @created_issue_record = project.issues.find_by(
      github_number: created_issue_number, is_pull_request: false
    )
  end

  # Batch-loads created-issue Issue rows for a collection of runs, mirroring
  # preload_source_pull_requests. Call from controllers rendering context
  # tooltips for many runs.
  def self.preload_created_issue_records(runs)
    targets = Array(runs).select do |r|
      r.created_issue_number.present? && r.project_id.present? &&
        !r.instance_variable_defined?(:@created_issue_record)
    end
    return if targets.empty?

    records = {}
    targets.group_by(&:project_id).each do |project_id, group|
      numbers = group.map(&:created_issue_number).uniq
      Issue.where(is_pull_request: false, project_id: project_id, github_number: numbers).each do |issue|
        records[[ issue.project_id, issue.github_number ]] = issue
      end
    end

    targets.each do |run|
      run.created_issue_record = records[[ run.project_id, run.created_issue_number ]]
    end
  end

  def queue_priority_label
    priority = QUEUE_PRIORITIES.fetch(queue_priority_tier) { UNKNOWN_PRIORITY }
    indicator = priority[:indicator]
    indicator ? "#{indicator} - #{priority[:label]}" : priority[:label]
  end

  # Queue context joins that aggregate candidate issue labels once per agent run
  # and resolve the same project owner used by Project#effective_owner.
  # Matches the issue either by direct association (issue_id) or by
  # source_pull_request_number for PR-based runs, merging labels from all
  # matching rows so a run with both an issue and a source PR considers
  # labels from both (matching compute_label_priority_tier). Both branches
  # constrain `i.project_id = agent_runs.project_id`, so cross-project
  # leakage is impossible even if `issue_id` were ever set across projects.
  QUEUE_LATERAL_JOIN = <<~SQL.squish.freeze
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb) AS labels
      FROM issues i, jsonb_array_elements(i.labels) AS elem
      WHERE (i.id = agent_runs.issue_id AND i.project_id = agent_runs.project_id)
         OR (i.project_id = agent_runs.project_id
             AND i.github_number = agent_runs.source_pull_request_number
             AND i.is_pull_request = TRUE)
    ) issue_labels ON TRUE
    LEFT JOIN projects p ON p.id = agent_runs.project_id
    LEFT JOIN LATERAL (
      SELECT COALESCE(
        p.created_by_id,
        (
          SELECT account_memberships.user_id
          FROM account_memberships
          WHERE account_memberships.account_id = p.account_id
            AND account_memberships.role = 3
          ORDER BY account_memberships.id
          LIMIT 1
        ),
        (
          SELECT users.id
          FROM users
          WHERE users.account_id = p.account_id
          ORDER BY users.id
          LIMIT 1
        )
      ) AS user_id
    ) project_owner ON TRUE
  SQL

  # Priority SQL using the LATERAL-joined issue_labels to avoid repeated
  # correlated subqueries. Reads per-project label names from
  # `projects.priority_labels` jsonb, falling back to literal tier keys
  # (P1/P2/P3) when the project's mapping is empty so behavior matches
  # Project#effective_priority_labels. Element matching is case-insensitive.
  #
  # NOTE: This SQL contains no interpolated values — the tier names are
  # hardcoded literals — so it is not a SQL injection vector.
  QUEUE_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN trigger_type = 'manual' THEN 0
      WHEN EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
        WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P1', ''), 'P1'))
      ) THEN 1
      WHEN EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
        WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P2', ''), 'P2'))
      ) THEN 2
      WHEN trigger_type = 'automatic' AND source_pull_request_number IS NOT NULL THEN 3
      WHEN EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
        WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P3', ''), 'P3'))
      ) THEN 4
      ELSE 5
    END
  SQL
  QUEUE_PRIORITY_SQL = Arel.sql(QUEUE_PRIORITY_CASE_SQL).freeze
  # Sub-sort within the same priority tier: PR-continuation work (runs
  # with a source_pull_request_number) sorts ahead of fresh-issue work.
  # Auto-continue is already gated by source_pull_request_number IS NOT NULL,
  # so this sub-sort is a no-op there; it primarily affects ties within
  # label_p1 / label_p2 / label_p3 / manual.
  IN_PROGRESS_CASE_SQL = <<~SQL.squish.freeze
    CASE WHEN source_pull_request_number IS NOT NULL THEN 0 ELSE 1 END
  SQL
  IN_PROGRESS_SQL = Arel.sql("#{IN_PROGRESS_CASE_SQL} ASC").freeze
  GOAL_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN goal IN ('create_issue', 'enhance_issue', 'analyze_issue') THEN 0
      ELSE 1
    END
  SQL
  GOAL_PRIORITY_SQL = Arel.sql(GOAL_PRIORITY_CASE_SQL).freeze
  # Cross-project fair-share: a project's count of currently in-flight runs
  # (running + claimed-queued). Projects with fewer in-flight runs sort ahead
  # so a high-volume project cannot fully starve a low-volume one. This is
  # the primary sort in QUEUE_ORDER; priority is strict only within a tie at
  # this and the user-active-count tier.
  PROJECT_ACTIVE_COUNT_EXPR_SQL = "COALESCE(project_active_counts.project_active_count, 0)"
  PROJECT_ACTIVE_COUNT_SQL = Arel.sql("#{PROJECT_ACTIVE_COUNT_EXPR_SQL} ASC").freeze
  USER_ACTIVE_COUNT_SQL = Arel.sql("COALESCE(user_active_counts.user_active_count, 0) ASC").freeze
  # Sort key order:
  #   project_active_count → cross-project round-robin
  #   user_active_count    → cross-user fairness within a project tie
  #   queue_priority       → strict priority within a project (manual > P1 > P2 > AC > P3 > AP)
  #   in_progress          → PR-continuation work ahead of fresh issues at the same tier
  #   goal_priority        → create_issue ahead of create_pr
  #   created_at, id       → FIFO tiebreaker
  QUEUE_ORDER = [
    PROJECT_ACTIVE_COUNT_SQL,
    USER_ACTIVE_COUNT_SQL,
    QUEUE_PRIORITY_SQL,
    IN_PROGRESS_SQL,
    GOAL_PRIORITY_SQL,
    { created_at: :asc, id: :asc }
  ].freeze
  STATUS_ORDER_CASE_SQL = <<~SQL.squish.freeze
    CASE WHEN agent_runs.status = 'running' THEN 0
         WHEN agent_runs.status = 'queued' AND agent_runs.temporal_workflow_id IS NOT NULL THEN 1
         WHEN agent_runs.status = 'paused' THEN 3
         ELSE 2 END
  SQL
  STATUS_ORDER_SQL = Arel.sql("#{STATUS_ORDER_CASE_SQL} ASC").freeze

  # Scope that adds the CTE and joins required by QUEUE_ORDER.
  # All queue-ordering methods use this instead of bare `queued`.
  # Filters to unclaimed queued runs (temporal_workflow_id IS NULL) so
  # claimed-but-not-yet-running runs are excluded from peek results.
  scope :unclaimed_with_priority, -> {
    unclaimed
      .with(
        project_active_counts: project_active_counts_cte,
        user_active_counts: user_active_counts_cte
      )
      .joins(QUEUE_LATERAL_JOIN)
      .joins("LEFT JOIN project_active_counts ON project_active_counts.project_id = agent_runs.project_id")
      .joins("LEFT JOIN user_active_counts ON user_active_counts.user_id = project_owner.user_id")
      .select(
        "agent_runs.*",
        "#{QUEUE_PRIORITY_CASE_SQL} AS queue_priority",
        "#{GOAL_PRIORITY_CASE_SQL} AS goal_priority",
        "#{PROJECT_ACTIVE_COUNT_EXPR_SQL} AS project_active_count",
        "COALESCE(user_active_counts.user_active_count, 0) AS user_active_count"
      )
  }

  # Scope for the agent runs index page: orders ALL unfinished runs by queue
  # priority so the user sees an approximate scheduler sort. Claimed queued
  # runs (temporal_workflow_id set) sort ahead of unclaimed ones at the same
  # tier; mirrors QUEUE_ORDER below STATUS_ORDER_SQL.
  scope :queue_order_display, -> {
    unfinished
      .with(
        project_active_counts: project_active_counts_cte,
        user_active_counts: user_active_counts_cte
      )
      .joins(QUEUE_LATERAL_JOIN)
      .joins("LEFT JOIN project_active_counts ON project_active_counts.project_id = agent_runs.project_id")
      .joins("LEFT JOIN user_active_counts ON user_active_counts.user_id = project_owner.user_id")
      .select(
        "agent_runs.*",
        "#{QUEUE_PRIORITY_CASE_SQL} AS queue_priority",
        "#{GOAL_PRIORITY_CASE_SQL} AS goal_priority",
        "#{PROJECT_ACTIVE_COUNT_EXPR_SQL} AS project_active_count",
        "COALESCE(user_active_counts.user_active_count, 0) AS user_active_count",
        "#{STATUS_ORDER_CASE_SQL} AS status_order"
      )
      .reorder(
        STATUS_ORDER_SQL,
        PROJECT_ACTIVE_COUNT_SQL,
        USER_ACTIVE_COUNT_SQL,
        QUEUE_PRIORITY_SQL,
        IN_PROGRESS_SQL,
        GOAL_PRIORITY_SQL,
        created_at: :asc,
        id: :asc
      )
  }

  # Scope that includes all queued runs (claimed + unclaimed) with priority
  # data. Used for display and peek operations that include claimed runs.
  scope :queued_with_priority, -> {
    queued
      .with(
        project_active_counts: project_active_counts_cte,
        user_active_counts: user_active_counts_cte
      )
      .joins(QUEUE_LATERAL_JOIN)
      .joins("LEFT JOIN project_active_counts ON project_active_counts.project_id = agent_runs.project_id")
      .joins("LEFT JOIN user_active_counts ON user_active_counts.user_id = project_owner.user_id")
      .select(
        "agent_runs.*",
        "#{QUEUE_PRIORITY_CASE_SQL} AS queue_priority",
        "#{GOAL_PRIORITY_CASE_SQL} AS goal_priority",
        "#{PROJECT_ACTIVE_COUNT_EXPR_SQL} AS project_active_count",
        "COALESCE(user_active_counts.user_active_count, 0) AS user_active_count"
      )
  }

  def self.project_active_counts_cte
    capacity_inflight
      .select("project_id, COUNT(*) AS project_active_count")
      .group(:project_id)
  end

  # CTE that counts in-flight runs (running + claimed queued) per effective
  # user (owner). Orphaned projects (created_by_id IS NULL) are attributed to
  # the account's fallback owner using the same COALESCE chain as
  # QUEUE_LATERAL_JOIN. Paused runs are excluded so a paused run does not
  # inflate a user's stride.
  def self.user_active_counts_cte
    Arel.sql(<<~SQL.squish)
      SELECT owner.user_id AS user_id, COUNT(*) AS user_active_count
      FROM agent_runs
      JOIN projects p ON p.id = agent_runs.project_id
      LEFT JOIN LATERAL (
        SELECT COALESCE(
          p.created_by_id,
          (
            SELECT account_memberships.user_id
            FROM account_memberships
            WHERE account_memberships.account_id = p.account_id
              AND account_memberships.role = 3
            ORDER BY account_memberships.id
            LIMIT 1
          ),
          (
            SELECT users.id
            FROM users
            WHERE users.account_id = p.account_id
            ORDER BY users.id
            LIMIT 1
          )
        ) AS user_id
      ) owner ON TRUE
      WHERE agent_runs.status = 'running'
             OR (agent_runs.status = 'queued' AND agent_runs.temporal_workflow_id IS NOT NULL)
      GROUP BY owner.user_id
    SQL
  end

  def self.next_queued_run
    next_queued_run_from(unclaimed_with_priority)
  end

  # Returns the next unclaimed queued run without claiming it.
  # Used to check per-user capacity before acquiring the lock.
  #
  # Runs whose project belongs to an account with a paused scheduler are
  # excluded so a "pause all" toggle can hold new starts while still
  # accepting new queue entries from the project trigger button.
  def self.peek_next_queued_run(exclude_ids: [], exclude_user_ids: [])
    scope = unclaimed_with_priority
      .joins(project: :account)
      .where(accounts: { scheduler_paused_at: nil })
      .where(projects: { scheduler_paused_at: nil })
      .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?
    scope = scope.where.not(project_owner: { user_id: exclude_user_ids }) if exclude_user_ids.any?
    next_queued_run_from(scope)
  end

  def self.schedulable_queued_with_priority
    queued_with_priority
      .joins(project: :account)
      .where(accounts: { scheduler_paused_at: nil })
      .where(projects: { scheduler_paused_at: nil })
      .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
  end

  def self.next_queued_run_from(scope)
    scope.reorder(QUEUE_ORDER).first
  end
  private_class_method :next_queued_run_from

  def runner_belongs_to_project_owner
    owner = project&.effective_owner
    return unless owner
    return if runner.user_id == owner.id

    errors.add(:runner, "must belong to the same user as the project owner")
  end

  # Atomically claims a queued run by setting temporal_workflow_id inside a
  # transaction with FOR UPDATE SKIP LOCKED. The status stays "queued" — the
  # run transitions to "running" only when RunAgentActivity#start! is called.
  # Returns nil if the run is no longer unclaimed or another process already
  # claimed it.
  #
  # @param target_id [Integer] the specific run to claim (identified by a
  #   prior peek_next_queued_run call)
  #
  # Note: if the transaction commits but the subsequent workflow start fails,
  # the run stays "queued" with a claimed marker. StaleRunDetectorJob handles
  # this by clearing the claim after STALE_CLAIMED_TIMEOUT.
  def self.claim_next_queued_run(target_id:)
    transaction do
      run = unclaimed.where(id: target_id).lock("FOR UPDATE SKIP LOCKED").first
      return nil unless run

      run.update!(temporal_workflow_id: CLAIMED_SENTINEL)
      run
    end
  end

  def existing_pr?
    source_pull_request_number.present?
  end

  def create_issue_goal?
    goal == "create_issue"
  end

  def create_pr_goal?
    goal == "create_pr"
  end

  def review_goal?
    goal == "review"
  end

  def enhance_issue_goal?
    goal == "enhance_issue"
  end

  def analyze_issue_goal?
    goal == "analyze_issue"
  end

  def focused?
    focus != "general"
  end

  # Whether this run has a cloned git repository in its container.
  # create_issue, enhance_issue, and analyze_issue goals skip cloning
  # unless they target an existing PR branch (source_pull_request_number present).
  def repo_cloned?
    return true unless create_issue_goal? || enhance_issue_goal? || analyze_issue_goal?

    source_pull_request_number.present?
  end

  def manual?
    trigger_type == "manual"
  end

  def automatic?
    trigger_type == "automatic"
  end

  def queued?
    status == "queued"
  end

  def claimed?
    status == "queued" && temporal_workflow_id.present?
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def cancellable?
    status.in?(UNFINISHED_STATUSES)
  end

  def running?
    status == "running"
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  def successful?
    status == "completed"
  end

  # Returns true when this run failed due to an operational/infrastructure
  # issue (runner exhaustion, timeout, auth expiry, rate limiting) rather
  # than a code-level failure. Used by the PR scanner's operational failure
  # breaker to detect when a PR is stalled due to infrastructure problems
  # that the agent cannot fix by retrying.
  #
  # A "failed" run is only operational when the error message indicates
  # runner exhaustion or rate limiting — other "failed" runs are assumed
  # to be code-level failures where a retry might help.
  def operational_failure?
    return false unless FAILURE_STATUSES.include?(status)
    return true if status.in?(%w[timeout auth_expired rate_limited])

    OPERATIONAL_FAILURE_KEYWORDS.any? do |keyword|
      error_message.to_s.downcase.include?(keyword.downcase)
    end
  end

  def infra_failure?
    return false unless PRE_MODEL_FAILURE_STATUSES.include?(status)
    return false if tokens_input.to_i > 0

    msg = error_message.to_s
    INFRA_FAILURE_KEYWORDS.any? { |keyword| msg.downcase.include?(keyword.downcase) }
  end

  def total_tokens
    tokens_input.to_i + tokens_output.to_i
  end

  # Returns total tokens consumed across all streaming turns.
  def streaming_total_tokens
    Array(streaming_turns_data).sum { |turn| turn["input_tokens"].to_i + turn["output_tokens"].to_i }
  end

  # Returns the average tokens per turn from streaming data.
  def streaming_avg_tokens_per_turn
    completed_turns = turns_completed.to_i
    return 0 if completed_turns <= 0

    streaming_total_tokens.to_f / completed_turns
  end

  def token_limit_exceeded?
    token_limit_status == "exceeded"
  end

  def token_limit_warning?
    token_limit_status == "warning"
  end

  # Resolves the effective max tokens per run for this agent run using the
  # full resolution chain: project override → user settings → account default
  # → global default, capped by the tenant guardrail. Memoized per AgentRun
  # instance so hot paths like token tracking and detail rendering do not
  # repeat user-settings resolution.
  def effective_max_tokens_per_run
    return @effective_max_tokens_per_run if defined?(@effective_max_tokens_per_run)

    @effective_max_tokens_per_run =
      project.account.tenant_max_tokens_per_run(
        project.max_tokens_per_run ||
        explicit_user_max_tokens_per_run ||
        project.account.default_max_tokens_per_run ||
        DEFAULT_MAX_TOKENS_PER_RUN
      )
  end

  def effective_max_execution_seconds
    return @effective_max_execution_seconds if defined?(@effective_max_execution_seconds)

    @effective_max_execution_seconds =
      explicit_user_max_execution_seconds || project.max_execution_seconds
  end

  # Returns the fraction of the token limit consumed (0.0–1.0+).
  def token_limit_usage_ratio
    total_tokens.to_f / effective_max_tokens_per_run
  end

  def resource_summary
    {
      peak_cpu_percent: peak_cpu_percent,
      peak_memory_bytes: peak_memory_bytes,
      avg_cpu_percent: avg_cpu_percent,
      avg_memory_bytes: avg_memory_bytes,
      samples: container_metrics_count
    }
  end

  PHASE_GROUP_ORDER = %w[queue setup prompt agent post cleanup].freeze

  def phase_timeline
    agent_run_phases
  end

  # Infers which phase group is currently in progress based on the run's
  # status and completed phases. Returns nil for finished runs or when
  # the active phase cannot be determined.
  def current_phase_group(phases: nil)
    return nil unless status.in?(%w[queued running])

    return "queue" if status == "queued"

    phases ||= phase_timeline.to_a
    completed_groups = phases.map(&:phase_group).uniq
    last_completed_index = PHASE_GROUP_ORDER.rindex { |g| completed_groups.include?(g) }

    return "setup" unless last_completed_index

    next_index = last_completed_index + 1
    PHASE_GROUP_ORDER[next_index] if next_index < PHASE_GROUP_ORDER.size
  end

  def phase_summary(phases: nil)
    phases ||= phase_timeline.to_a
    return empty_phase_summary if phases.empty?

    # Callers pass phases from the ordered association; avoid resorting hot paths.
    ordered_phases = phases
    first_phase = ordered_phases.first
    queue_seconds = [ (first_phase.started_at - created_at).to_i, 0 ].max
    grouped = ordered_phases.group_by(&:phase_group).transform_values do |entries|
      entries.sum(&:duration_seconds)
    end

    {
      queue_seconds: queue_seconds,
      setup_seconds: grouped.fetch("setup") { 0 },
      prompt_seconds: grouped.fetch("prompt") { 0 },
      agent_seconds: grouped.fetch("agent") { 0 },
      post_seconds: grouped.fetch("post") { 0 },
      cleanup_seconds: grouped.fetch("cleanup") { 0 },
      observed_seconds: ordered_phases.sum(&:duration_seconds),
      first_phase_at: first_phase.started_at,
      last_phase_at: ordered_phases.last.finished_at
    }
  end

  def start!
    with_lock do
      reload

      # Guard: don't resurrect a run already marked finished by
      # StaleRunDetectorJob or another process.
      if finished?
        errors.add(:base, "cannot start a finished agent run")
        raise ActiveRecord::RecordInvalid, self
      end

      update!(status: "running", started_at: Time.current, completed_at: nil)
    end
  end

  def complete!(result_commit: nil, pr_url: nil, pr_number: nil, issue_url: nil, issue_number: nil)
    with_lock do
      reload
      if finished?
        false
      else
        update!(
          status: "completed",
          completed_at: Time.current,
          result_commit_sha: result_commit,
          pull_request_url: pr_url,
          pull_request_number: pr_number,
          created_issue_url: issue_url,
          created_issue_number: issue_number,
          duration_seconds: duration
        )
      end
    end
  end

  def complete_no_output!(reason: "no_changes")
    with_lock do
      reload
      if finished?
        false
      else
        update!(
          status: "no_output",
          completed_at: Time.current,
          error_message: reason,
          duration_seconds: duration
        )
      end
    end
  end

  def result_url
    pull_request_url || created_issue_url
  end

  # Returns cross-repo issues created during this run, filtered by role.
  def upstream_issues
    (cross_repo_issues || []).select { |i| i["role"] == "upstream" }
  end

  def downstream_issues
    (cross_repo_issues || []).select { |i| i["role"] == "downstream" }
  end

  def cross_repo_issue_pair?
    upstream_issues.any? && downstream_issues.any?
  end

  def fail!(error: nil)
    with_lock do
      reload
      if finished?
        false
      else
        update!(
          status: "failed",
          completed_at: Time.current,
          error_message: error,
          duration_seconds: duration
        )
      end
    end
  end

  def pause!(violation_type:, context: nil, decision_point: "agent_run.pause")
    with_lock do
      reload
      unless running?
        log_orchestration_decision(
          action: "pause",
          decision_point: decision_point,
          status: "noop",
          signals: { violation_type: violation_type, context: context, current_status: status },
          result: { status: status }
        )
        return false
      end

      update!(
        status: "paused",
        paused_at: Time.current,
        guardrail_violation_type: violation_type,
        guardrail_context: context
      )
      log_orchestration_decision(
        action: "pause",
        decision_point: decision_point,
        status: "applied",
        signals: { violation_type: violation_type, context: context },
        result: { status: status, paused_at: paused_at }
      )
      true
    end
  end

  def paused?
    status == "paused"
  end

  def resume!(decision_point: "agent_run.resume")
    with_lock do
      reload
      unless paused?
        log_orchestration_decision(
          action: "resume",
          decision_point: decision_point,
          status: "noop",
          signals: { current_status: status, paused_at: paused_at },
          result: { status: status }
        )
        return false
      end

      update!(
        status: "queued",
        started_at: nil,
        completed_at: nil,
        duration_seconds: nil,
        paused_at: nil,
        guardrail_violation_type: nil,
        guardrail_context: nil,
        temporal_workflow_id: nil,
        temporal_run_id: nil
      )
      log_orchestration_decision(
        action: "resume",
        decision_point: decision_point,
        status: "applied",
        signals: { guardrail_violation_type: guardrail_violation_type_before_last_save, paused_at: paused_at_before_last_save },
        result: { status: status }
      )
      true
    end
  end

  def cancel!
    with_lock do
      reload
      if finished?
        false
      else
        update!(
          status: "cancelled",
          completed_at: Time.current,
          duration_seconds: duration
        )
      end
    end
  end

  def timeout!(error: nil, guardrail_violation_type: nil, guardrail_context: nil)
    with_lock do
      reload
      if finished?
        false
      else
        attributes = {
          status: "timeout",
          completed_at: Time.current,
          error_message: error,
          duration_seconds: duration
        }
        attributes[:guardrail_violation_type] = guardrail_violation_type unless guardrail_violation_type.nil?
        attributes[:guardrail_context] = guardrail_context unless guardrail_context.nil?
        update!(attributes)
      end
    end
  end

  # True when this run was force-timed-out externally (by `dev:cleanup` or
  # `StaleRunDetectorJob`), not by the runner itself. The in-flight Temporal
  # activity uses this to suppress runner circuit-breaker bookkeeping for
  # failures that the external cleanup induced, not the runner.
  def cancelled_by_cleanup?
    return false unless status == "timeout"

    error_message.to_s.start_with?(STALE_CLEANUP_ERROR_PREFIX, STALE_DETECTOR_ERROR_PREFIX)
  end

  def retried?
    status == "retried"
  end

  def retry!(decision_point: "agent_run.retry", signals: {}, result: {})
    with_lock do
      update!(status: "retried")
      log_orchestration_decision(
        action: "retry",
        decision_point: decision_point,
        status: "applied",
        signals: signals.merge(previous_status: status_before_last_save),
        result: result.merge(status: status)
      )
    end
  end

  def auth_expired?
    status == "auth_expired"
  end

  def auth_expire!(error: nil, runner: nil, runner_key: nil)
    update!(
      status: "auth_expired",
      completed_at: Time.current,
      error_message: error,
      auth_provider: runner || runner_key,
      duration_seconds: duration
    )
  end

  def rate_limited?
    status == "rate_limited"
  end

  # Returns true when the container is retained for post-failure diagnostics.
  # A retained container has a non-nil TTL that hasn't expired yet.
  def container_retained?
    container_retained_until.present? && container_retained_until > Time.current
  end

  def rate_limit!(error: nil, reset_at: nil)
    update!(
      status: "rate_limited",
      completed_at: Time.current,
      error_message: error,
      rate_limited_until: reset_at,
      duration_seconds: duration
    )
  end

  # Creates a log entry for this agent run.
  #
  # @param type [String] Log type: stdout, stderr, system, or metric
  # @param content [String] The log content
  # @param metadata [Hash] Optional metadata to store as JSON
  # @return [AgentRunLog] The created log entry
  def log!(type, content, metadata: nil)
    agent_run_logs.create!(
      log_type: type,
      content: normalize_log_content(content),
      metadata: metadata
    )
  end

  # Agent execution integration methods.
  # These delegate to AgentRuns::Execute and Prompts::BuildForIssue services.

  # Executes the agent for this run using agent-harness.
  #
  # @param prompt [String] The prompt to send to the agent
  # @param timeout [Integer, nil] Optional timeout in seconds; when nil, the
  #   underlying AgentHarness configuration determines the default
  # @return [AgentRuns::Execute::Result] Result with success/failure and response
  def execute_agent(prompt, timeout: nil)
    args = { agent_run: self, prompt: prompt }
    args[:timeout] = timeout unless timeout.nil?

    AgentRuns::Execute.call(**args)
  end

  # Builds a prompt for this run's issue using the PromptBuilder.
  #
  # @return [String, nil] The built prompt, or nil if no issue is attached
  def prompt_for_issue
    return nil unless issue

    Prompts::BuildForIssue.call(issue: issue, project: project, github_client: project.github_token&.client, agent_run: self)
  end

  # Returns the agent's stdout output joined as a single string.
  # Strips the raw JSON envelope when stdout is a Claude CLI --output-format json
  # response, extracting just the assistant's result text.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The agent summary text (may be empty)
  def agent_summary(limit: 500)
    extract_text_from_stdout(logs_text(log_type: "stdout", limit: limit))
  end

  # Returns the agent's output, preferring stdout but falling back to stderr.
  # Useful for issue-goal runs where agents may write drafted content to stderr.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The best available agent output (may be empty)
  def agent_summary_with_stderr_fallback(limit: 500)
    summary = extract_text_from_stdout(logs_text(log_type: "stdout", limit: limit))
    return summary if summary.present?

    logs_text(log_type: "stderr", limit: limit)
  end

  def log_orchestration_decision(action:, decision_point:, status:, signals:, result:)
    OrchestrationDecision.record(
      project: project,
      issue: issue,
      agent_run: self,
      decision_point: decision_point,
      action: action,
      status: status,
      signals: signals,
      result: result
    )
  end
  private :log_orchestration_decision

  # Returns the prompt for this run: custom_prompt if provided,
  # otherwise delegates to goal-specific prompt builders.
  #
  # @return [String, nil] The prompt to send to the agent
  def effective_prompt
    base = custom_prompt.presence || prompt_for_goal
    return base unless agent_run_marketplace_entries.exists?

    runner_key = runner&.runner_key || RunnerSupport.runner_key_for_agent_type(agent_type)
    MarketplaceEntries::InjectIntoPrompt.call(agent_run: self, prompt: base, provider_key: runner_key)
  end

  # Returns the base prompt for the review goal.
  # The review_goal_requires_pull_request validation ensures
  # source_pull_request_number is always present for review goals.
  #
  # @return [String] The review prompt
  def prompt_for_review
    "Review pull request ##{source_pull_request_number} in #{project.full_name}."
  end

  # Returns the runner that actually produced the output for this run.
  # Prefers final_runner (the runner that ultimately completed successfully)
  # when present, otherwise falls back to agent_type (the originally requested runner).
  # Note: whether a fallback occurred should be determined via runner tracking
  # fields (e.g., runners_attempted / runner_switches), not by final_runner alone.
  #
  # @return [String] The effective runner name
  def effective_runner
    RunnerSupport.runner_key_for_agent_type(final_runner.presence || agent_type)
  end

  alias_method :effective_provider, :effective_runner

  def final_runner_record
    return preloaded_final_runner_record if preloaded_final_runner_record_loaded

    owner = project&.effective_owner
    return unless owner

    return unless final_runner.present?

    runner_id = Runner.id_from_routing_key(final_runner)
    owner.runners.with_discarded.find_by(id: runner_id) if runner_id
  end

  # Returns the Runner record that reflects which runner actually ran the
  # agent. Prefers the final runner (post-fallback) when resolvable, falling
  # back to the initially-assigned runner. Handles both routing-key and
  # runner-key forms of final_runner via Runner.for_identifier. Returns
  # nil if neither can be resolved.
  def effective_runner_record
    Runner.for_identifier(project&.effective_owner, final_runner, include_discarded: true) ||
      runner ||
      Runner.with_discarded.find_by(id: runner_id)
  end

  alias_method :effective_provider_record, :effective_runner_record

  def attempted_runners_by_routing_key
    owner = project&.effective_owner
    return {} unless owner

    routing_ids = runners_attempted.filter_map do |attempt|
      Runner.id_from_routing_key(attempt["runner"] || attempt["provider"])
    end
    return {} if routing_ids.empty?

    owner.runners.with_discarded.where(id: routing_ids).index_by(&:routing_key)
  end

  alias_method :attempted_providers_by_routing_key, :attempted_runners_by_routing_key

  # Records a runner attempt in the runners_attempted array.
  #
  # @param runner [String] The runner name
  # @param success [Boolean] Whether the attempt succeeded
  # @param error_type [String, nil] Type of error if failed (e.g., "rate_limited", "error")
  def record_runner_attempt(runner, success:, error_type: nil, error_message: nil, duration_seconds: nil,
                            diagnostics: nil, resolved_model_id: nil, resolved_provider_id: nil,
                            resolution_source: nil)
    attempt = {
      "runner" => runner,
      "success" => success,
      "attempted_at" => Time.current.iso8601
    }
    attempt["error_type"] = error_type if error_type.present?
    sanitized_error_message = sanitize_runner_attempt_error_message(error_message)
    attempt["error_message"] = sanitized_error_message if sanitized_error_message.present?
    attempt["duration_seconds"] = duration_seconds if duration_seconds.present?
    attempt["diagnostics"] = sanitize_runner_attempt_diagnostics(diagnostics) if diagnostics.present?
    attempt["resolved_model_id"] = resolved_model_id if resolved_model_id.present?
    attempt["resolved_provider_id"] = resolved_provider_id if resolved_provider_id.present?
    attempt["resolution_source"] = resolution_source if resolution_source.present?

    self.runners_attempted = (runners_attempted || []) + [ attempt ]
    save!
  end

  # Logs a runner switch and increments the switch counter.
  #
  # @param from [String] The runner being switched from
  # @param to [String] The runner being switched to
  # @param reason [String] Why the switch occurred
  def log_runner_switch!(from, to, reason)
    log!("system", "Runner fallback: #{from} -> #{to} (#{reason})")
    increment!(:runner_switches)
  end

  alias_method :log_provider_switch!, :log_runner_switch!

  def sanitize_runner_attempt_diagnostics(diagnostics)
    return unless diagnostics.is_a?(Hash)

    diagnostics.deep_stringify_keys.each_with_object({}) do |(key, value), sanitized|
      sanitized[key] = case value
      when Hash
        sanitize_runner_attempt_diagnostics(value)
      when Array
        value.map do |entry|
          case entry
          when Hash
            sanitize_runner_attempt_diagnostics(entry)
          when String
            sanitize_runner_attempt_error_message(entry)
          else
            entry
          end
        end
      when String
        sanitize_runner_attempt_error_message(value)
      else
        value
      end
    end.reject { |_, value| value.nil? || value == "" || value == {} || value == [] }
  end

  # Container management integration methods.
  # These delegate to Containers::Provision for actual implementation.

  # Provisions a Docker container for this agent run.
  #
  # When worktree_path is blank, an empty workspace directory is auto-created
  # for in-container git clone. When set, the existing path is bind-mounted.
  #
  # @param options [Hash] Override default container options
  # @return [Containers::Provision::Result] Result with container_id on success
  # @raise [Containers::Provision::ProvisionError] When container creation fails
  def provision_container(**options)
    pooled_result = Containers::PoolManager.new(project: project).acquire(agent_run: self, **options)
    if pooled_result&.success?
      @container_service = pooled_result[:service]
      update!(container_id: pooled_result[:container_id], container_host: pooled_result[:container_host])
      return pooled_result
    end

    @container_service = Containers::Provision.new(
      agent_run: self,
      worktree_path: worktree_path.presence,
      **options
    )
    result = @container_service.provision
    if result.success?
      update!(container_id: result[:container_id], container_host: result[:container_host])
      PoolReplenishmentJob.perform_later(project_id)
    end
    result
  end

  # Executes a command in the provisioned container.
  #
  # @param command [String, Array<String>] Command to execute
  # @param timeout [Integer] Timeout in seconds (default from container options)
  # @param stream [Boolean] Whether to stream output to agent logs
  # @return [Containers::Provision::Result] Result with stdout, stderr, exit_code
  # @raise [Containers::Provision::ProvisionError] When container not provisioned
  # @raise [Containers::Provision::TimeoutError] When command times out
  def execute_in_container(command, timeout: nil, stream: true, env: {}, preparation: nil)
    ensure_container_service!
    @container_service.execute(command, timeout: timeout, stream: stream, env: env, preparation: preparation)
  end

  # Cleans up the provisioned container.
  #
  # @param force [Boolean] Force kill if container doesn't stop gracefully
  # @return [void]
  def cleanup_container(force: false)
    return if container_id.blank? && @container_service.nil?

    if Containers::PoolManager.cleanup_claimed_container(agent_run: self, force: force)
      @container_service = nil
      update!(container_id: nil)
      return
    end

    ensure_container_service!
    @container_service.cleanup(force: force)
    @container_service = nil
    update!(container_id: nil)
  rescue Containers::Provision::Error
    # Container may already be gone; clear the reference anyway
    @container_service = nil
    update!(container_id: nil)
    # The container is gone but the workspace volume may still exist.
    # Provision#cleanup would normally handle this in its ensure block,
    # but we never reached it, so clean up the volume directly.
    cleanup_orphaned_workspace_volume
  end

  # Executes a block with a provisioned container, ensuring cleanup.
  #
  # @param options [Hash] Override default container options
  # @yield [self] The agent run with provisioned container
  # @return [Object] The return value of the block
  def with_container(**options, &)
    Containers::Provision.with_container(
      agent_run: self,
      worktree_path: worktree_path.presence,
      **options
    ) do |service|
      @container_service = service
      yield(self)
    ensure
      @container_service = nil
    end
  end

  # Lazily generates and persists a proxy token for runs that were created
  # before the proxy_token column existed. Returns the token.
  # Uses atomic conditional update to avoid race conditions between
  # concurrent callers.
  def ensure_proxy_token!
    return proxy_token if proxy_token.present?

    token = SecureRandom.hex(32)

    # Atomically set the token only if it is still NULL in the database to
    # avoid races between concurrent callers.
    updated_rows = self.class.where(id: id, proxy_token: nil).update_all(proxy_token: token)

    if updated_rows == 1
      self.proxy_token = token
    else
      reload
    end

    proxy_token
  end

  private

  def set_initiating_user_from_current_user
    self.initiating_user ||= Current.user
  end

  def initiating_user_belongs_to_project_account
    return if initiating_user.account_id == project.account_id

    errors.add(:initiating_user, "must belong to the same account as the project")
  end

  def sync_legacy_provider_bridge_columns
    LEGACY_PROVIDER_ATTRIBUTE_BRIDGES.each do |legacy_name, runner_name|
      runner_value = self[runner_name]
      legacy_value = self[legacy_name]

      if will_save_change_to_attribute?(runner_name)
        self[legacy_name] = runner_value
      elsif will_save_change_to_attribute?(legacy_name)
        self[runner_name] = legacy_value
      elsif runner_value.nil? && !legacy_value.nil?
        self[runner_name] = legacy_value
      elsif legacy_value.nil? && !runner_value.nil?
        self[legacy_name] = runner_value
      end
    end
  end

  # Guard: only fires when these specific columns are being changed, so unrelated
  # saves skip this check. Safe because no code path clears expected_draft_review_count
  # independently — both columns are always set together at creation or merge time.
  def draft_review_round_tracking_is_consistent
    return unless count_toward_draft_review_round?
    return unless will_save_change_to_count_toward_draft_review_round? ||
      will_save_change_to_expected_draft_review_count?

    if expected_draft_review_count.blank?
      errors.add(:expected_draft_review_count, "is required when counting toward draft review rounds")
    end
  end

  def extract_text_from_stdout(raw_stdout)
    return raw_stdout if raw_stdout.blank?

    response = parse_structured_stdout(raw_stdout)
    if response&.error.present?
      return "Agent encountered an error: #{response.error}"
    end
    return response.output if response&.output.present?

    extract_text_from_multiline_json(raw_stdout) || raw_stdout
  end

  def extract_text_from_multiline_json(raw_stdout)
    results = []
    error_messages = []

    raw_stdout.lines.last(STDOUT_TAIL_LINES).each do |line|
      line = line.strip
      next unless line.start_with?("{") && line.include?('"type"')

      begin
        parsed = JSON.parse(line)
      rescue JSON::ParserError
        next
      end

      next unless parsed.is_a?(Hash)

      case parsed["type"]
      when "result"
        if parsed["is_error"]
          error_messages << (parsed["result"] || "Unknown error").to_s
        elsif parsed.key?("result")
          text = parsed["result"].to_s.strip
          results << text if text.present?
        end
      when "error"
        error_obj = parsed["error"]
        if error_obj.is_a?(Hash)
          msg = error_obj.dig("data", "message") || error_obj["message"] || error_obj["name"]
          error_messages << msg.to_s
        elsif error_obj.present?
          error_messages << error_obj.to_s
        end
        # Also capture top-level "message" field (e.g., {"type":"error","message":"fatal API error"})
        if parsed.key?("message") && parsed["message"].present?
          error_messages << parsed["message"].to_s
        end
      when "text"
        part = parsed["part"]
        text = part.is_a?(Hash) ? part["text"].to_s.strip : parsed["text"].to_s.strip
        results << text if text.present?
      end
    end

    if error_messages.present? && results.empty?
      return "Agent encountered an error: #{error_messages.uniq.first.truncate(500)}"
    end
    return nil if results.empty?

    results.join("\n\n").presence
  end

  def parse_structured_stdout(raw_stdout)
    structured_stdout_parsers.each do |runner_key, parser|
      parser_input = structured_stdout_input_for(runner_key, raw_stdout)
      response = parser.parse_container_output(stdout: parser_input)
      return response if structured_stdout_response?(response, parser_input)
    end

    nil
  end

  def structured_stdout_response?(response, raw_stdout)
    response.error.present? || response.output != raw_stdout
  end

  def structured_stdout_parsers
    [ effective_runner, "claude", "codex" ].uniq.filter_map do |runner_key|
      parser = structured_stdout_parser_for(runner_key)
      [ runner_key, parser ] if parser
    end
  end

  def structured_stdout_parser_for(runner_key)
    harness_key = RunnerSupport.harness_runner_key_for(runner_key).to_sym
    AgentHarness.provider(harness_key)
  rescue AgentHarness::ConfigurationError
    nil
  end

  def structured_stdout_input_for(runner_key, raw_stdout)
    return raw_stdout unless runner_key == "codex"

    raw_stdout.lines.last(STDOUT_TAIL_LINES).join
  end

  def normalize_log_content(content)
    text = content.to_s
    return text.delete("\x00") if text.encoding == Encoding::UTF_8 && text.valid_encoding?

    text.dup.force_encoding(Encoding::UTF_8).scrub.delete("\x00")
  end

  def sanitize_runner_attempt_error_message(message)
    return nil if message.blank?

    normalized = normalize_log_content(message)
    redacted = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
    redacted = redact_runner_attempt_secrets(redacted)
    redacted.truncate(MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH)
  end

  def redact_runner_attempt_secrets(text)
    RUNNER_ATTEMPT_SECRET_PATTERNS.reduce(text) do |result, (pattern, replacement)|
      result.gsub(pattern, replacement)
    end
  end

  def logs_text(log_type:, limit:)
    agent_run_logs
      .where(log_type: log_type)
      .order(:created_at)
      .limit(limit)
      .pluck(:content)
      .join("\n")
      .strip
  end

  def review_goal_requires_pull_request
    if goal == "review" && source_pull_request_number.blank?
      errors.add(:source_pull_request_number, "is required for review goals")
    end
  end

  def issue_goal_requires_issue
    if goal.in?(%w[enhance_issue analyze_issue]) && issue_id.blank?
      errors.add(:issue, "is required for #{goal} goals")
    end
  end

  def prompt_for_goal
    if review_goal?
      prompt_for_review
    elsif enhance_issue_goal?
      prompt_for_enhance_issue
    elsif analyze_issue_goal?
      prompt_for_analyze_issue
    else
      prompt_for_issue
    end
  end

  def prompt_for_enhance_issue
    return nil unless issue

    "Enhance issue ##{issue.github_number} in #{project.full_name}. " \
      "Read the issue description and all comments, then add a comment that either " \
      "provides implementation context (relevant files, architecture notes, suggested approach) " \
      "or asks specific clarifying questions the user needs to answer."
  end

  def prompt_for_analyze_issue
    return nil unless issue

    "Analyze issue ##{issue.github_number} in #{project.full_name}. " \
      "Assess whether there is sufficient context to start implementation."
  end

  def empty_phase_summary
    {
      queue_seconds: 0,
      setup_seconds: 0,
      prompt_seconds: 0,
      agent_seconds: 0,
      post_seconds: 0,
      cleanup_seconds: 0,
      observed_seconds: 0,
      first_phase_at: nil,
      last_phase_at: nil
    }
  end

  # Removes the named Docker volume for this agent run if it exists.
  # No-op for worktree-based runs (they use bind mounts, not named volumes).
  def cleanup_orphaned_workspace_volume
    return if worktree_path.present? # bind-mount runs don't use named volumes

    volume_name = "paid-workspace-#{id}"
    backend = Containers.backend_for(container_host)
    volume = backend.get_volume(volume_name, host: container_host)
    backend.delete_volume(volume)
  rescue Docker::Error::NotFoundError
    # Volume already removed, nothing to do
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "container_manager.orphaned_volume_cleanup_failed",
      agent_run_id: id,
      volume_name: volume_name,
      error: e.message
    )
  end

  # Ensures @container_service is available, reconnecting from persisted
  # container_id if needed (e.g., when called from a different Temporal activity).
  def ensure_container_service!
    return if @container_service

    raise Containers::Provision::ProvisionError, "Container not provisioned" if container_id.blank?

    @container_service = Containers::Provision.reconnect(
      agent_run: self,
      container_id: container_id,
      worktree_path: worktree_path
    )
  end

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def has_prompt_source
    return if issue.present? || custom_prompt.present? || source_pull_request_number.present?

    errors.add(:base, "must have either an issue, a custom prompt, or a source pull request")
  end

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end

  def snapshot_mcp_servers
    return if mcp_server_snapshot.present? && mcp_server_snapshot.any?

    definitions = project.mcp_server_definitions.enabled.order(:id)
    self.mcp_server_snapshot = definitions.map(&:to_snapshot)
  end

  def update_project_last_agent_run_at
    Project
      .where(id: project_id)
      .where("last_agent_run_at IS NULL OR last_agent_run_at < ?", created_at)
      .update_all(last_agent_run_at: created_at, updated_at: Time.current)
  end

  # Treat the auto-created user setting's global default as "inherit" so the
  # account default still applies unless the user has explicitly confirmed an
  # override. A later save of the settings row is the durable signal we have
  # that the persisted default value was intentionally kept by the user.
  def explicit_user_max_tokens_per_run
    user_setting = AgentRuns::UserSettingsResolver.call(project: project, strict: false, create: false)
    return nil unless user_setting

    max_tokens_per_run = user_setting.max_tokens_per_run
    return nil if max_tokens_per_run.blank?
    return max_tokens_per_run if max_tokens_per_run != DEFAULT_MAX_TOKENS_PER_RUN
    return max_tokens_per_run if user_setting.updated_at > user_setting.created_at

    nil
  end

  def explicit_user_max_execution_seconds
    user_setting = AgentRuns::UserSettingsResolver.call(project: project, strict: false, create: false)
    user_setting&.max_execution_seconds
  end

  def update_completed_agent_runs_counter_cache
    completed_agent_runs_counter_deltas.each do |project_id, delta|
      Project.update_counters(project_id, completed_agent_runs_count: delta)
    end
  end

  def reload_project_counter_cache_association
    return unless association(:project).loaded?

    if previous_changes.key?("project_id") && previous_changes["project_id"].first.present?
      association(:project).reset
    elsif project.present? && !project.destroyed?
      fresh_counts = Project.where(id: project.id)
        .pick(:agent_runs_count, :completed_agent_runs_count)
      return unless fresh_counts

      project.agent_runs_count, project.completed_agent_runs_count = fresh_counts
      project.clear_attribute_changes([ "agent_runs_count", "completed_agent_runs_count" ])
    end
  end

  def just_finished?
    previous_changes.key?("status") && finished?
  end

  def enqueue_quality_metrics_collection
    QualityMetricsCollectionJob.perform_later(id)
    HumanFeedbackCollectionJob.set(wait: 5.minutes).perform_later(id) if successful?
  end

  def enqueue_anomaly_detection
    AnomalyDetectionJob.perform_later(id)
  end

  def just_started_running?
    previous_changes.key?("status") && status == "running"
  end

  private :explicit_user_max_tokens_per_run, :explicit_user_max_execution_seconds

  def project_counter_cache_state_changed?
    will_save_change_to_project_id? || will_save_change_to_status?
  end

  def store_project_counter_cache_state
    @project_counter_cache_state_before_last_commit = {
      project_id: project_id_in_database,
      status: status_in_database
    }
  end

  def store_destroyed_project_counter_cache_state
    @project_counter_cache_state_before_last_commit = {
      project_id: project_id,
      status: status
    }
  end

  def completed_agent_runs_counter_deltas
    previous_state = @project_counter_cache_state_before_last_commit || {}
    previous_project_id = previous_state[:project_id]
    previous_status = previous_state[:status]

    if destroyed?
      counter_cache_deltas_for_completed_transition(
        previous_project_id: previous_project_id,
        previous_status: previous_status,
        current_project_id: nil,
        current_status: nil
      )
    else
      previous_project_id ||= previous_changes.fetch("project_id", [ project_id, project_id ]).first
      previous_status ||= previous_changes.fetch("status", [ status, status ]).first

      counter_cache_deltas_for_completed_transition(
        previous_project_id: previous_project_id,
        previous_status: previous_status,
        current_project_id: project_id,
        current_status: status
      )
    end
  ensure
    @project_counter_cache_state_before_last_commit = nil
  end

  def counter_cache_deltas_for_completed_transition(previous_project_id:, previous_status:, current_project_id:, current_status:)
    deltas = Hash.new(0)
    deltas[previous_project_id] -= 1 if previous_project_id.present? && previous_status == "completed"
    deltas[current_project_id] += 1 if current_project_id.present? && current_status == "completed"
    deltas.reject { |_project_id, delta| delta.zero? }
  end

  def just_timed_out_issue_goal?
    previous_changes.key?("status") && status == "timeout" && create_issue_goal?
  end

  def recovery_decision_required?
    previous_changes.key?("status") && status.in?(recovery_decision_statuses)
  end

  def recovery_decision_statuses
    AgentRun::FAILURE_STATUSES + %w[completed no_output cancelled]
  end

  def enqueue_failure_recovery_decision
    FailureRecoveryDecisionJob.perform_later(id, failure_recovery_snapshot)
  end

  def enqueue_issue_goal_timeout_retry
    RetryTimedOutIssueGoalJob.perform_later(id)
  end

  def failure_recovery_snapshot
    {
      "status" => status,
      "error_message" => error_message,
      "guardrail_violation_type" => guardrail_violation_type,
      "final_runner" => final_runner,
      "runners_attempted" => runners_attempted,
      "runner_switches" => runner_switches,
      "parent_workflow_id" => parent_workflow_id
    }
  end

  def enqueue_container_metrics_collection
    ContainerMetricsCollectionJob.perform_later(id) if container_id.present?
  end

  def broadcast_project_updates
    if previous_changes.key?("status") || previous_changes.key?("issue_id") || previous_changes.key?("agent_type")
      project.broadcast_agent_runs_update
      project.broadcast_agent_runs_list_update
      project.broadcast_stats_update
      project.broadcast_cost_snapshot_update if previous_changes.key?("status")
      # Only broadcast issues updates when they can affect auto-pick eligibility
      # or when the associated issue/agent type changes. This avoids redundant
      # re-renders during intermediate status transitions (e.g., queued→running).
      if issue_id.present?
        should_broadcast_issues = false

        if previous_changes.key?("issue_id") || previous_changes.key?("agent_type")
          should_broadcast_issues = true
        elsif previous_changes.key?("status")
          from_status, to_status = previous_changes["status"]
          from_blocking = AUTO_PICK_BLOCKING_STATUSES.include?(from_status)
          to_blocking = AUTO_PICK_BLOCKING_STATUSES.include?(to_status)

          if from_blocking != to_blocking
            should_broadcast_issues = true
          end
        end

        project.broadcast_issues_update if should_broadcast_issues
      end

      DashboardBroadcastJob.perform_later(project.account_id) if finished?
    end

    if previous_changes.key?("status")
      LiveDashboardBroadcastJob.perform_later(project.account_id, id)
    end

    project.broadcast_agent_run_detail_update(self)
  end

  def invalidate_runner_options_cache_on_change
    return unless previous_changes.key?("agent_type") || previous_changes.key?("final_runner")

    self.class.invalidate_runner_options_cache(
      account_id: project.account_id,
      project_id: project_id
    )
  end
end
