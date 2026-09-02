# frozen_string_literal: true

class AgentRun < ApplicationRecord
  attribute :focus, :string, default: "general"
  attribute :execution_origin, :string, default: "paid_native"
  attribute :external_metadata, :json, default: {}
  attribute :verification_result, :json, default: {}
  attr_accessor :preloaded_final_runner_record, :preloaded_final_runner_record_loaded

  MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH = 500
  MAX_PROVIDER_ATTEMPT_ERROR_MESSAGE_LENGTH = MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH
  RUNNER_ATTEMPT_SECRET_PATTERNS = [
    [ /\bsk-[A-Za-z0-9][A-Za-z0-9_-]{10,}\b/, "[REDACTED:api_key]" ],
    [ /\b(?:ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|gh[oushr]_[A-Za-z0-9]{36,})\b/, "[REDACTED:github_token]" ],
    [ %r{x-access-token:[^@/\s]+@github\.com}, "x-access-token:[REDACTED]@github.com" ],
    [ /(Bearer\s)[A-Za-z0-9\-._~+\/]+=*/i, "\\1[REDACTED]" ]
  ].freeze
  STATUSES = %w[queued running paused completed no_output failed cancelled timeout token_budget_exceeded retried auth_expired rate_limited].freeze
  # Must include every value RunnerSupport.agent_type_for produces for a
  # container-executable runner key (RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS),
  # otherwise dequeue-time runner binding writes an agent_type that can never be
  # re-validated — poisoning the dispatch queue. The invariant is enforced by
  # spec/lib/runner_support_spec.rb ("returns a valid agent type for every
  # container-executable runner key"). When you add a runner key, add its
  # agent_type here too.
  AGENT_TYPES = %w[claude_code cursor codex copilot gemini opencode kilocode pi omp api devin factory internal_agent].freeze
  FOCUSES = %w[general ci_fix review_feedback merge_conflict conversation performance_regression issue_implementation label_action].freeze # @spec FOCUSED-RUN-001
  # analyze_issue is automation-only (triggered via Automation::Decision), not exposed in the manual run form.
  GOALS = %w[create_pr create_issue review enhance_issue analyze_issue lid_planning create_feature].freeze
  # RDR-056 (Strict TDD): the run-scoped write-guard phase for projects with
  # tdd_mode != "off". nil means the run is not TDD-governed (existing
  # behavior). See Tdd::WriteGuard for the enforced allowed/forbidden matrix.
  TDD_PHASES = %w[test_writing test_fixing refactor].freeze
  # Goals that read an issue body and reason about it without needing aggressive
  # codebase exploration. Routed to economical runners by default so they don't
  # land on heavy-exploration runners that consume 15-20x more tokens.
  # @spec RUNNER-SCHED-011
  LIGHTWEIGHT_GOALS = %w[enhance_issue analyze_issue].freeze
  TRIGGER_TYPES = %w[manual automatic].freeze
  EXECUTION_ORIGINS = %w[paid_native external].freeze
  ACTIVE_STATUSES = %w[running].freeze
  FINISHED_STATUSES = %w[completed no_output failed cancelled timeout token_budget_exceeded retried auth_expired rate_limited].freeze
  FAILURE_STATUSES = %w[failed timeout token_budget_exceeded auth_expired rate_limited].freeze
  TERMINAL_FAILURE_STATUSES = (FAILURE_STATUSES + %w[cancelled]).freeze
  RETRY_PRIORITY_INHERITANCE_STATUSES = (FAILURE_STATUSES + %w[no_output]).freeze
  QUALITY_EXCLUDED_STATUSES = %w[timeout token_budget_exceeded auth_expired rate_limited].freeze
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
  # Infrastructure failures that occur before the LLM runner is reached.
  # These should not count toward the operational failure escalation breaker
  # because the agent never had a chance to work on the PR.
  PRE_RUNNER_INFRA_KEYWORDS = [
    "Failed to pull image",
    "Failed to start service container",
    "getaddrinfo",
    "Temporary failure in name resolution",
    "connection slots are reserved"
  ].freeze
  PRE_MODEL_FAILURE_STATUSES = %w[failed no_output].freeze
  # Keywords that identify a purely transient provider/infrastructure outage.
  # These outages resolve on their own once capacity returns — no human can
  # fix them. Runs matching these patterns are excluded from the operational-
  # failure escalation breaker so that a temporary provider outage does not
  # page a human reviewer who cannot help.
  PROVIDER_UNAVAILABLE_KEYWORDS = [
    "providers exhausted",
    "runners exhausted"
  ].freeze
  # GitHub rejects a push under .github/workflows/ (or any operation needing a
  # permission the App lacks) with a permanent error: "refusing to allow a
  # GitHub App ... without `workflows` permission". It fails identically on
  # every retry until the App's permissions change, so callers must treat these
  # as terminal and stop re-enqueuing the issue (see MarkAgentRunFailedActivity).
  PUSH_PERMISSION_REJECTION_KEYWORDS = [
    "refusing to allow a GitHub App to create or update",
    "without `workflows` permission"
  ].freeze

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
  GUARDRAIL_VIOLATION_TYPES = %w[loop_detected token_limit cost_limit time_limit anomaly no_progress token_budget].freeze
  AUTO_PICK_BLOCKING_STATUSES = UNFINISHED_STATUSES
  # Statuses that mean work is already in flight for an issue/PR and must block
  # queueing a duplicate. Includes +rate_limited+ because a parked run holds the
  # work slot and will re-queue on recovery — excluding it let re-triggering
  # pumps (e.g. the PR CI-fix scanner) mint a fresh run every cycle while the
  # prior one sat parked, producing hundreds of duplicate runs per issue (#129).
  DEDUP_BLOCKING_STATUSES = (UNFINISHED_STATUSES + %w[rate_limited]).freeze
  TOKEN_LIMIT_STATUSES = %w[ok warning exceeded].freeze
  DEFAULT_MAX_TOKENS_PER_RUN = 10_000_000
  MAX_STALE_REQUEUES = 2
  MAX_STALE_SKIPS = 3
  # Maximum times a run parked in "rate_limited" (runner unavailable / transient
  # infra) may be re-queued in place before it is left terminally failed.
  # Reuses the stale_requeue_count column. Higher than MAX_STALE_REQUEUES because
  # runner-availability windows (rate limits, open circuits) are expected to clear.
  MAX_RATE_LIMITED_REQUEUES = 5
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
  PREVIEW_SESSION_EXTERNAL_METADATA_KEY = "preview_session".freeze
  EXECUTION_INGRESS_METADATA_KEY = "execution_ingress".freeze

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
  has_many :style_guide_ab_test_assignments, dependent: :destroy
  has_many :configuration_experiment_assignments, dependent: :destroy
  has_many :bundle_outcomes, dependent: :destroy
  has_many :strategy_experiment_assignments, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all
  has_many :execution_usages, dependent: :destroy
  has_one :execution_usage, -> { order(provisioned_at: :desc, terminated_at: :desc, id: :desc) },
    class_name: "ExecutionUsage"
  has_many :quality_metrics, dependent: :destroy
  has_many :style_guide_run_exposures, dependent: :destroy
  has_many :orchestration_decisions, dependent: :nullify
  has_one :worktree, dependent: :nullify
  has_one :model_selection, dependent: :destroy
  has_one :decision_record, dependent: :nullify
  has_one :agent_run_session_summary, dependent: :destroy
  has_many :agent_run_anomalies, dependent: :destroy
  has_many :knowledge_usage_stats, dependent: :destroy
  has_many :agent_run_marketplace_entries, -> { order(:position) }, dependent: :destroy
  has_many :egress_security_events, dependent: :destroy
  # :nullify (not :destroy) — the ledger exists to durably track external
  # resources independent of the agent run that created them, so destroying
  # the run must not delete rows that still need reconciliation/cleanup.
  has_many :execution_resource_ledger_entries, dependent: :nullify
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
  before_validation :refresh_queue_entered_at, if: :should_refresh_queue_entered_at?
  before_validation :assign_default_tdd_phase, on: :create
  before_create :generate_proxy_token
  before_create :snapshot_mcp_servers

  before_update :store_project_counter_cache_state, if: :project_counter_cache_state_changed?
  before_destroy :store_destroyed_project_counter_cache_state

  after_commit :update_agent_run_counter_caches, on: [ :create, :update, :destroy ]
  after_commit :reload_project_counter_cache_association, on: [ :create, :update, :destroy ]
  after_commit :broadcast_project_updates, on: [ :create, :update ]
  after_commit :update_project_last_agent_run_at, on: :create, unless: :synthetic_operational_run?
  after_commit :invalidate_runner_options_cache_on_change, on: [ :create, :update ]
  after_commit :enqueue_quality_metrics_collection, on: :update, if: :real_run_just_finished?
  after_commit :enqueue_anomaly_detection, on: :update, if: :real_run_just_finished?
  after_commit :enqueue_resource_profile_refresh, on: :update, if: :real_run_just_finished?
  after_commit :enqueue_container_metrics_collection, on: :update, if: :container_metrics_seed_due?
  after_commit :enqueue_issue_goal_timeout_retry, on: :update, if: :just_timed_out_issue_goal?
  after_commit :enqueue_failure_recovery_decision, on: :update, if: :recovery_decision_required?
  after_commit :record_dispatch_circuit_breaker_outcome, on: :update, if: :real_run_just_finished?

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :goal, presence: true, inclusion: { in: GOALS }
  validates :focus, presence: true, inclusion: { in: FOCUSES }
  validates :tdd_phase, inclusion: { in: TDD_PHASES }, allow_nil: true
  validates :execution_origin, presence: true, inclusion: { in: EXECUTION_ORIGINS }
  validate :review_goal_requires_pull_request
  validate :issue_goal_requires_issue
  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }
  validates :plan_doc_source, length: { maximum: 1000 }
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
  validates :external_source_key, inclusion: { in: Interop::Catalog.external_execution_source_keys }, allow_nil: true
  validates :external_run_key, length: { maximum: 255 }, allow_nil: true,
    uniqueness: { scope: %i[project_id external_source_key] }
  validates :adoption_mode_snapshot, inclusion: { in: Project::ADOPTION_MODES }, allow_nil: true
  validates :iterations, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_input, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_output, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :infra_cost_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :billed_duration_seconds, numericality: { greater_than_or_equal_to: 0 }
  validates :runner_backend, length: { maximum: 64 }, allow_nil: true
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
  validate :has_prompt_source, on: :create, unless: :external_execution?
  validate :draft_review_round_tracking_is_consistent
  validate :external_execution_fields_are_consistent

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
  scope :admitted_not_started, -> { running.where.not(temporal_workflow_id: nil).where(started_at: nil) }
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
  # Rate-limited runs whose recovery window has elapsed and are therefore due to
  # be re-queued in place. StaleRunDetectorJob reactivates these — without it,
  # rate_limited is effectively terminal (no other code path re-queues it).
  scope :rate_limited_due, ->(now = Time.current) {
    rate_limited.where.not(rate_limited_until: nil).where(rate_limited_until: ..now)
  }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :capacity_inflight, -> { running.or(claimed) }
  scope :excluding_preview_provisioning, -> {
    where(preview_provisioning_exclusion_sql)
  }
  scope :reported_create_pr, -> {
    where(goal: "create_pr")
      .excluding_preview_provisioning
      .excluding_synthetic
  }
  scope :finished, -> { where(status: FINISHED_STATUSES) }
  scope :paid_native, -> { where(execution_origin: "paid_native") }
  scope :external_execution, -> { where(execution_origin: "external") }
  # Synthetic operational runs (e.g. live-preview provisioning) reuse the
  # agent-run lifecycle to drive infrastructure but never execute a real agent
  # and cannot produce a PR/issue/review artifact. Excluded from user-facing run
  # history and metrics so previews do not masquerade as ordinary agent runs or
  # inflate totals. Keyed off the `synthetic` flag rather than `agent_type`,
  # because `internal_agent` is shared with legitimate externally-ingested runs
  # (AgentRuns::IngestExternal). See `synthetic_operational_run?`.
  scope :excluding_synthetic, -> { where(synthetic: false) }
  scope :with_execution_usage, -> { joins(:execution_usages).distinct }
  scope :by_runner_backend, ->(backend) { where(runner_backend: backend.to_s) }

  # Transcript/diagnostic payload columns are never rendered by list views
  # (dashboard cards, queue preview, activity stream); skipping them keeps
  # fat JSON/TEXT columns off list queries. custom_prompt is deliberately
  # KEPT by default: agent_run_context uses it as the context fallback for
  # runs without an issue or PR link. Call sites that never render context
  # (recent activity) pass extra: %w[custom_prompt].
  LIST_PAYLOAD_EXCLUDED_COLUMNS = %w[
    streaming_turns_data external_metadata mcp_server_snapshot
    mcp_provisioned_servers screenshot_hints review_proxy_diagnostics
  ].freeze

  scope :excluding_list_payload, ->(extra: []) {
    excluded = LIST_PAYLOAD_EXCLUDED_COLUMNS + Array(extra)
    select((column_names - excluded).map { |c| "#{table_name}.#{c}" })
  }

  def update_columns(attributes)
    super(attributes)
  end

  def settings_user
    initiating_user || project&.effective_owner
  end

  def external_execution?
    execution_origin == "external"
  end

  def preview_provisioning?
    ActiveModel::Type::Boolean.new.cast(external_metadata&.[](PREVIEW_SESSION_EXTERNAL_METADATA_KEY))
  end

  # @spec EXEC-INGRESS-002
  def execution_ingress_policy
    ExecutionRunners::IngressPolicy.from_metadata(
      external_metadata.is_a?(Hash) ? external_metadata[EXECUTION_INGRESS_METADATA_KEY] : {}
    )
  end

  # @spec EXEC-INGRESS-002
  def self.preview_execution_metadata(preview_session:, granted_by:)
    metadata = {
      PREVIEW_SESSION_EXTERNAL_METADATA_KEY => true,
      EXECUTION_INGRESS_METADATA_KEY => ExecutionRunners::IngressPolicy.default_deny(
        capabilities: [
          ExecutionRunners::IngressCapability.build(
            kind: "preview",
            scope: "paid_mediated_tunnel",
            expires_at: preview_session.expires_at || 1.hour.from_now,
            authentication: { required: true, type: "authenticated_proxy" },
            granted_at: Time.current,
            granted_by: preview_granted_by(granted_by)
          )
        ]
      ).to_h
    }

    metadata
  end

  def self.preview_granted_by(granted_by)
    granted_by.respond_to?(:id) ? "user:#{granted_by.id}" : granted_by.to_s
  end
  private_class_method :preview_granted_by

  scope :recent, -> { order(created_at: :desc) }
  scope :started_before, ->(time) { where("started_at < ?", time) }
  scope :updated_before, ->(time) { where("updated_at < ?", time) }
  scope :stale_running, -> { running.where(stale_running_condition_sql(now: Time.current)) }
  scope :stale_claimed, -> { claimed.or(admitted_not_started).updated_before(stale_claimed_cutoff) }
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
    %w[status agent_type branch_name trigger_type goal duration_seconds tokens_input tokens_output tokens_total cost_cents created_at started_at completed_at temporal_workflow_id effective_runner]
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

  def queue_entered_at_for_current_episode
    queue_entered_at || created_at
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

  # RDR-048 (#2947): count inflight runs against a per-host ceiling. A run's
  # container_host stays blank from claim time until provisioning commits a
  # real backend resource, so the host it was admitted against is recorded in
  # external_metadata["planned_container_host"] (see
  # ProcessRunQueueJob#start_claimed_run). Attribute such not-yet-provisioned
  # rows to their planned host instead of charging every blank row to the
  # local bucket — otherwise a single queue pass over-admits remote hosts
  # (their count stays 0 during the claim window) while starving the local
  # host with runs admitted elsewhere. Once container_host is set by a real
  # provision/pool result it is authoritative and the planned value is ignored.
  def self.capacity_inflight_for_host(container_host)
    capacity_inflight.where(
      "COALESCE(NULLIF(container_host, ''), " \
      "COALESCE(external_metadata->>'planned_container_host', '')) IN (:scope)",
      scope: host_scope_for(container_host)
    )
  end

  def self.active_count_for_host(container_host)
    # A host is a shared physical resource that runs workloads for multiple
    # accounts, so the count must span all tenants — otherwise RunAdmission
    # (tenant-scoped) undercounts and the unauthenticated Prometheus path
    # reads zero. See active_count_global for the same RLS concern.
    TenantContext.with_system_access do
      capacity_inflight_for_host(container_host).count
    end
  end

  # Returns the total count of capacity-inflight runs across all accounts,
  # hosts, and projects. Used by the global concurrent execution limit
  # (Capacity::GlobalLimit) to enforce a deployment-wide ceiling on total
  # concurrent executions — the "how many cloud machines am I willing to pay
  # for right now" control.
  def self.active_count_global
    # `agent_runs` has FORCE ROW LEVEL SECURITY, so the count is only truly
    # global when RLS is bypassed. CheckRunCapacityActivity runs under
    # TenantContext.with(account) and Metrics::PrometheusCollector reads via
    # the unauthenticated /api/metrics endpoint — either way the raw count
    # would be scoped to one tenant (or zero). Bypass here so the method
    # matches its "across all accounts" contract regardless of caller.
    TenantContext.with_system_access { capacity_inflight.count }
  end

  # Returns the count of active create_pr runs for the given account.
  # Used to enforce the account-level create_pr concurrency cap.
  #
  # Synthetic operational runs (e.g. live-preview provisioning) reuse the
  # create_pr pipeline to drive container provisioning but never produce a PR.
  # They are excluded so opening a preview cannot consume one of the tenant's
  # PR-work slots and block unrelated issue/PR automation.
  def self.active_create_pr_count_for_account(account)
    capacity_inflight
      .joins(:project)
      .where(projects: { account_id: account.id })
      .reported_create_pr
      .count
  end

  def self.preview_provisioning_exclusion_sql(table_name: self.table_name)
    sanitize_sql_array([
      "COALESCE(#{table_name}.external_metadata->>?, 'false') != 'true'",
      PREVIEW_SESSION_EXTERNAL_METADATA_KEY
    ])
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

  def container_host_selection
    raw = external_metadata.fetch("container_host_selection", {})
    raw.is_a?(Hash) ? raw.stringify_keys : {}
  end

  def host_placement_decision
    raw = external_metadata.fetch("host_placement_decision", {})
    raw.is_a?(Hash) ? raw.stringify_keys : {}
  end

  # Extracts the persisted egress policy snapshot stored under
  # `external_metadata["egress_policy"]`. The snapshot is written by the
  # resolver before provisioning and is the authoritative record of which
  # destinations a run was actually allowed to reach.
  def egress_policy_snapshot
    return nil unless external_metadata.is_a?(Hash)

    snapshot = external_metadata["egress_policy"]
    snapshot.is_a?(Hash) ? snapshot : nil
  end

  # Resolves the Docker host that owns this run's named workspace volume for
  # cleanup. ProcessRunQueueJob clears container_host at claim time and only
  # restores it from a real provision/pool result (see start_claimed_run), so
  # in multi-host mode a worker that dies mid-provision — after
  # prepare_workspace! created a remote paid-workspace-* volume but before a
  # backend recorded container_host — still carries its admission host in
  # external_metadata["planned_container_host"]. Fall back to that so volume
  # cleanup probes the backend that actually owns the volume instead of the
  # local default, which would leak the remote volume. Mirrors the COALESCE
  # fallback used by active_count_for_host.
  def workspace_volume_host
    container_host.presence || external_metadata["planned_container_host"].presence
  end

  def self.stale_running?(agent_run, now: Time.current)
    agent_run.status == "running" &&
      agent_run.started_at.present? &&
      agent_run.started_at < stale_running_cutoff(goal: agent_run.goal, now: now)
  end

  def self.stale_claimed?(agent_run, now: Time.current)
    agent_run.temporal_workflow_id.present? &&
      agent_run.updated_at.present? &&
      agent_run.updated_at < stale_claimed_cutoff(now: now) &&
      (agent_run.status == "queued" || (agent_run.status == "running" && agent_run.started_at.nil?))
  end

  def should_refresh_queue_entered_at?
    queued? && (queue_entered_at.blank? || will_save_change_to_status?)
  end
  private :should_refresh_queue_entered_at?

  def refresh_queue_entered_at
    self.queue_entered_at = Time.current
  end
  private :refresh_queue_entered_at

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
  # Priority ordering for the run queue (9 tiers). Work category (PR
  # continuation vs. fresh issue) is the primary discriminator, with
  # priority label (P1 > P2 > P3 > none) secondary within each category:
  #   0 = manual runs (user pre-emption — highest, any category)
  #   1 = PR continuation, P1 user-defined label
  #   2 = PR continuation, P2 user-defined label
  #   3 = PR continuation, P3 user-defined label
  #   4 = PR continuation, no priority label (auto-continue)
  #   5 = fresh issue, P1 user-defined label
  #   6 = fresh issue, P2 user-defined label
  #   7 = fresh issue, P3 user-defined label
  #   8 = fresh issue, no priority label (auto-pick — lowest)
  #
  # This ordering means the highest-priority *workable* PR continuation
  # work is always scheduled before any fresh-issue work, and fresh issues
  # are only considered once no PR continuation work remains queued. See
  # RDR-047 for the rationale: labeling a fresh issue P1 must not let it
  # leapfrog a ready, unlabeled PR follow-up.
  #
  # The manual tier does not split by category — a manual PR-continuation
  # run and a manual fresh-issue run both land in tier 0. IN_PROGRESS_SQL
  # in QUEUE_ORDER breaks that tie (PR continuation first); every other
  # tier already fixes source_pull_request_number nullness by construction,
  # so IN_PROGRESS_SQL is a no-op there.
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
  QUEUE_PRIORITIES = { # @spec QUEUE-TIER-001
    manual: { label: "Manual", indicator: 1 },
    pr_p1: { label: "PR · P1", indicator: 2 },
    pr_p2: { label: "PR · P2", indicator: 3 },
    pr_p3: { label: "PR · P3", indicator: 4 },
    pr_continue: { label: "Auto-continue", indicator: 5 },
    issue_p1: { label: "P1", indicator: 6 },
    issue_p2: { label: "P2", indicator: 7 },
    issue_p3: { label: "P3", indicator: 8 },
    auto_pick: { label: "Auto-pick", indicator: 9 }
  }.freeze
  UNKNOWN_PRIORITY = { label: "Unknown", indicator: nil }.freeze
  QUEUE_GOAL_PRIORITY_GOALS = %w[create_issue enhance_issue analyze_issue lid_planning create_feature].freeze

  def queue_priority_tier # @spec QUEUE-TIER-002
    return :manual if manual?

    category = existing_pr? ? "pr" : "issue"
    case label_priority_tier
    when "P1" then :"#{category}_p1"
    when "P2" then :"#{category}_p2"
    when "P3" then :"#{category}_p3"
    else category == "pr" ? :pr_continue : :auto_pick
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
  # Resolves to 1/2/3 for whichever of P1/P2/P3 matches (highest wins), or 4
  # when no priority label matches. Shared by both branches of
  # QUEUE_PRIORITY_CASE_SQL below (PR-continuation and fresh-issue) via
  # interpolation, so the label-matching logic is defined once instead of
  # once per category. For a given row, only one branch's copy is ever
  # evaluated (SQL CASE only evaluates the taken THEN/ELSE), so this does
  # not change the number of EXISTS checks Postgres runs per row.
  LABEL_RANK_CASE_SQL = <<~SQL.squish.freeze
    CASE
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
      WHEN EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(issue_labels.labels) AS label(value)
        WHERE LOWER(label.value) = LOWER(COALESCE(NULLIF(p.priority_labels->>'P3', ''), 'P3'))
      ) THEN 3
      ELSE 4
    END
  SQL
  # trigger_type = 'automatic' is not re-checked below the first WHEN:
  # TRIGGER_TYPES only has 'manual'/'automatic', so anything that reaches
  # the second WHEN is already known to be automatic.
  QUEUE_PRIORITY_CASE_SQL = <<~SQL.squish.freeze # @spec QUEUE-TIER-001
    CASE
      WHEN trigger_type = 'manual' THEN 0
      WHEN source_pull_request_number IS NOT NULL THEN (#{LABEL_RANK_CASE_SQL})
      ELSE (#{LABEL_RANK_CASE_SQL}) + 4
    END
  SQL
  QUEUE_PRIORITY_SQL = Arel.sql(QUEUE_PRIORITY_CASE_SQL).freeze
  # Tie-break within the manual tier only: a manual PR-continuation run
  # sorts ahead of a manual fresh-issue run. Every other tier already
  # fixes source_pull_request_number nullness by construction (all PR
  # tiers require it NOT NULL, all issue tiers require it NULL), so this
  # is a no-op everywhere except tier 0.
  IN_PROGRESS_CASE_SQL = <<~SQL.squish.freeze
    CASE WHEN source_pull_request_number IS NOT NULL THEN 0 ELSE 1 END
  SQL
  IN_PROGRESS_SQL = Arel.sql("#{IN_PROGRESS_CASE_SQL} ASC").freeze
  GOAL_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN goal IN ('#{QUEUE_GOAL_PRIORITY_GOALS.join("', '")}') THEN 0
      ELSE 1
    END
  SQL
  GOAL_PRIORITY_SQL = Arel.sql(GOAL_PRIORITY_CASE_SQL).freeze
  REVIEW_PICKUP_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE WHEN goal = 'review' THEN 0 ELSE 1 END
  SQL
  REVIEW_PICKUP_PRIORITY_SQL = Arel.sql(REVIEW_PICKUP_PRIORITY_CASE_SQL).freeze
  # Cross-project fair-share: a project's count of currently in-flight runs
  # (running + claimed-queued). Projects with fewer in-flight runs sort ahead
  # so a high-volume project cannot fully starve a low-volume one. This is
  # the primary sort in the default fair-share queue mode; strict-priority
  # mode omits these active-count keys entirely.
  PROJECT_ACTIVE_COUNT_EXPR_SQL = "COALESCE(project_active_counts.project_active_count, 0)"
  PROJECT_ACTIVE_COUNT_SQL = Arel.sql("#{PROJECT_ACTIVE_COUNT_EXPR_SQL} ASC").freeze
  USER_ACTIVE_COUNT_SQL = Arel.sql("COALESCE(user_active_counts.user_active_count, 0) ASC").freeze
  # Visible queue sort key order in the default fair-share mode:
  #   project_active_count → cross-project round-robin
  #   user_active_count    → cross-user fairness within a project tie
  #   queue_priority       → strict priority within a project
  #                          (manual > PR·P1 > PR·P2 > PR·P3 > PR-continue > issue·P1 > issue·P2 > issue·P3 > auto-pick)
  #   in_progress          → tie-break within the manual tier only (PR continuation first)
  #   goal_priority        → create_issue ahead of create_pr
  #   created_at, id       → FIFO tiebreaker
  QUEUE_ORDER = [ # @spec QUEUE-TIER-003 @spec QUEUE-TIER-005 @spec EAGER-QUEUE-008
    PROJECT_ACTIVE_COUNT_SQL,
    USER_ACTIVE_COUNT_SQL,
    QUEUE_PRIORITY_SQL,
    IN_PROGRESS_SQL,
    GOAL_PRIORITY_SQL,
    { created_at: :asc, id: :asc }
  ].freeze
  STRICT_PRIORITY_QUEUE_ORDER = [
    QUEUE_PRIORITY_SQL,
    IN_PROGRESS_SQL,
    GOAL_PRIORITY_SQL,
    { created_at: :asc, id: :asc }
  ].freeze
  # Scheduler sort used for dequeueing and queue displays. The review-only
  # tiebreak ensures short review runs drain before create_pr runs when all
  # visible priority keys are otherwise tied. Strict-priority mode uses the
  # same review-only tiebreak without the active-count fairness keys.
  SCHEDULER_QUEUE_ORDER = [
    PROJECT_ACTIVE_COUNT_SQL,
    USER_ACTIVE_COUNT_SQL,
    QUEUE_PRIORITY_SQL,
    IN_PROGRESS_SQL,
    GOAL_PRIORITY_SQL,
    REVIEW_PICKUP_PRIORITY_SQL,
    { created_at: :asc, id: :asc }
  ].freeze
  STRICT_PRIORITY_SCHEDULER_QUEUE_ORDER = [
    QUEUE_PRIORITY_SQL,
    IN_PROGRESS_SQL,
    GOAL_PRIORITY_SQL,
    REVIEW_PICKUP_PRIORITY_SQL,
    { created_at: :asc, id: :asc }
  ].freeze

  def self.resolve_queue_fairness_mode(mode)
    mode.to_s.presence_in(TenantSetting::QUEUE_FAIRNESS_MODES) || TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE
  end

  def self.queue_order_for(mode:)
    case resolve_queue_fairness_mode(mode)
    when "strict_priority"
      STRICT_PRIORITY_QUEUE_ORDER
    else
      QUEUE_ORDER
    end
  end

  def self.scheduler_queue_order_for(mode:)
    case resolve_queue_fairness_mode(mode)
    when "strict_priority"
      STRICT_PRIORITY_SCHEDULER_QUEUE_ORDER
    else
      SCHEDULER_QUEUE_ORDER
    end
  end

  def self.queue_order_display_for(mode:)
    [ STATUS_ORDER_SQL, *scheduler_queue_order_for(mode:) ]
  end

  STATUS_ORDER_CASE_SQL = <<~SQL.squish.freeze
    CASE WHEN agent_runs.status = 'running' THEN 0
         WHEN agent_runs.status = 'queued' AND agent_runs.temporal_workflow_id IS NOT NULL THEN 1
         WHEN agent_runs.status = 'paused' THEN 3
         ELSE 2 END
  SQL
  STATUS_ORDER_SQL = Arel.sql("#{STATUS_ORDER_CASE_SQL} ASC").freeze

  # Scope that adds the CTE and joins required by queue ordering.
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
  scope :queue_order_display, ->(mode: TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE) {
    where(status: UNFINISHED_STATUSES)
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
      .reorder(*queue_order_display_for(mode:))
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

  def self.next_queued_run(mode: TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE)
    next_queued_run_from(unclaimed_with_priority, mode:)
  end

  # Returns the next unclaimed queued run without claiming it.
  # Used to check per-user capacity before acquiring the lock.
  #
  # Runs whose project belongs to an account with a paused scheduler are
  # excluded so a "pause all" toggle can hold new starts while still
  # accepting new queue entries from the project trigger button.
  def self.peek_next_queued_run(mode: TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE,
    queue_fairness_mode_filter: nil,
    exclude_ids: [], exclude_project_ids: [], exclude_user_ids: [],
    exclude_account_create_pr_ids: [], exclude_account_ids: [])
    scope = unclaimed_with_priority
      .joins(project: :account)
      .where(accounts: { scheduler_paused_at: nil })
      .where(projects: { scheduler_paused_at: nil })
      .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
      .where("agent_runs.trigger_type = 'manual' OR projects.paused = FALSE")
    if queue_fairness_mode_filter.present?
      scope = scope.joins("INNER JOIN tenant_settings ON tenant_settings.account_id = projects.account_id")
      scope = scope.where(tenant_settings: { queue_fairness_mode: resolve_queue_fairness_mode(queue_fairness_mode_filter) })
    end
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?
    scope = scope.where.not(project_id: exclude_project_ids) if exclude_project_ids.any?
    scope = scope.where.not(project_owner: { user_id: exclude_user_ids }) if exclude_user_ids.any?
    scope = scope.where.not(projects: { account_id: exclude_account_ids }) if exclude_account_ids.any?
    if exclude_account_create_pr_ids.any?
      scope = scope.where(
        "agent_runs.goal != 'create_pr' OR projects.account_id NOT IN (?)",
        exclude_account_create_pr_ids
      )
    end
    next_queued_run_from(scope, mode:)
  end

  def self.schedulable_queued_with_priority(mode: TenantSetting::DEFAULT_QUEUE_FAIRNESS_MODE)
    queued_with_priority
      .joins(project: :account)
      .where(accounts: { scheduler_paused_at: nil })
      .where(projects: { scheduler_paused_at: nil })
      .where("agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL")
      .where("agent_runs.trigger_type = 'manual' OR projects.paused = FALSE")
      .reorder(*queue_order_for(mode:))
  end

  def self.next_queued_run_from(scope, mode:)
    scope.reorder(*scheduler_queue_order_for(mode:)).first
  end
  private_class_method :next_queued_run_from

  def self.retry_trigger_type_for(project:, source_pull_request_number:, goal:)
    return "automatic" if project.blank? || source_pull_request_number.blank?

    # A completed run for the same PR/goal is a cycle reset boundary (mirrors
    # PullRequests::ProgressState#create_pr_progress?), so only the failure
    # streak after the most recent successful run is eligible for inheritance.
    latest_pr_run = where(
      project: project,
      source_pull_request_number: source_pull_request_number,
      goal: goal,
      status: (RETRY_PRIORITY_INHERITANCE_STATUSES + %w[completed])
    ).order(Arel.sql("COALESCE(completed_at, updated_at, created_at) DESC"), id: :desc).first

    return "automatic" if latest_pr_run.blank? || latest_pr_run.status == "completed"

    latest_pr_run.trigger_type == "manual" ? "manual" : "automatic"
  end

  def self.pr_history_scope(project:, pr_number:, issue: nil)
    project.agent_runs.where(
      "issue_id = :issue_id OR source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
      issue_id: issue&.id,
      pr_num: pr_number
    )
  end

  def self.pr_auto_continue_tokens_used(project:, pr_number:, issue: nil)
    pr_history_scope(project:, pr_number:, issue:)
      .where(trigger_type: "automatic")
      .pick(Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"))
      .to_i
  end

  # @spec LID-RUNS-004
  # Finds the lid_planning run that opened a given Planning PR, if any.
  # Used by the review-goal prompt path to detect that a PR is a Planning PR
  # and route the follow-up through the intent-correction flow rather than
  # generic code review.
  def self.planning_run_for_pr(project_id:, pr_number:)
    where(
      project_id: project_id,
      goal: "lid_planning",
      pull_request_number: pr_number
    ).order(created_at: :desc).first
  end

  def runner_belongs_to_project_owner
    owner = project&.effective_owner
    return unless owner
    return if runner.user_id == owner.id

    errors.add(:runner, "must belong to the same user as the project owner")
  end

  # Atomically claims a queued run by setting temporal_workflow_id inside a
  # transaction with FOR UPDATE SKIP LOCKED. ProcessRunQueueJob transitions the
  # run to "running" once the workflow is admitted.
  # Returns nil if the run is no longer unclaimed or another process already
  # claimed it.
  #
  # @param target_id [Integer] the specific run to claim (identified by a
  #   prior peek_next_queued_run call)
  #
  # Note: if the transaction commits but the subsequent workflow start fails,
  # ProcessRunQueueJob leaves the workflow id in place and keeps the run
  # claimed so StaleRunDetectorJob can cancel a potentially orphaned workflow.
  def self.claim_next_queued_run(target_id:)
    transaction do
      run = unclaimed.where(id: target_id).lock("FOR UPDATE SKIP LOCKED").first
      return nil unless run

      run.update!(temporal_workflow_id: CLAIMED_SENTINEL)
      run
    end
  end

  def existing_pr? # @spec QUEUE-TIER-002
    source_pull_request_number.present?
  end

  def queue_order_rank
    [
      queue_priority_rank,
      existing_pr? ? 0 : 1,
      queue_goal_priority_rank,
      created_at,
      id
    ]
  end

  def scheduler_queue_rank
    [
      queue_priority_rank,
      existing_pr? ? 0 : 1,
      queue_goal_priority_rank,
      review_goal? ? 0 : 1,
      created_at,
      id
    ]
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

  def lid_planning_goal?
    goal == "lid_planning"
  end

  def create_feature_goal?
    goal == "create_feature"
  end

  def assign_default_tdd_phase
    return if tdd_phase.present?
    return unless create_pr_goal?
    return unless project&.tdd_mode.in?(%w[strict non_strict])

    self.tdd_phase = inferred_tdd_phase
  end
  private :assign_default_tdd_phase

  def inferred_tdd_phase
    return "test_writing" if source_pull_request_number.blank?

    pr_record = source_pull_request_record
    return "test_writing" unless pr_record&.has_label?(Tdd::ReturnToTestReview::TESTS_APPROVED_LABEL)

    "test_fixing"
  end
  private :inferred_tdd_phase

  # RDR-056 (Strict TDD) run-scoped write-guard phase predicates.
  # @spec TDD-GUARD-001
  def tdd_test_writing_phase?
    tdd_phase == "test_writing"
  end

  # @spec TDD-GUARD-002
  def tdd_test_fixing_phase?
    tdd_phase == "test_fixing"
  end

  # @spec TDD-GUARD-003
  def tdd_refactor_phase?
    tdd_phase == "refactor"
  end

  def tdd_governed?
    tdd_phase.present?
  end

  # Synthetic operational runs (e.g. live-preview provisioning) reuse the
  # agent-run lifecycle to drive container provisioning but never execute a real
  # agent and cannot produce a PR, issue, or review artifact. They must bypass
  # run-quality collection, anomaly detection, dispatch circuit-breaker
  # accounting, and failure-recovery decisions so they don't record bogus
  # create-pr metrics or enqueue follow-up work for a run that produces nothing.
  # Marked by an explicit `synthetic` flag at creation rather than `agent_type`,
  # since `internal_agent` is also a legitimate externally-ingested run type.
  def synthetic_operational_run?
    synthetic?
  end

  def plan_docs_present?
    return true if plan_doc_source.present?

    Array(external_metadata["plan_docs"]).any? { |doc| doc.respond_to?(:[]) && doc["name"].present? }
  end

  def focused? # @spec FOCUSED-RUN-001
    focus != "general"
  end

  # Whether this run has a cloned git repository in its container.
  # create_issue and analyze_issue goals skip cloning unless they target
  # an existing PR branch (source_pull_request_number present).
  # enhance_issue runs containerized with repo access (RDR-052).
  # create_feature always clones so the agent can read existing code and RDRs.
  def repo_cloned?
    return true if create_feature_goal?
    return true unless create_issue_goal? || analyze_issue_goal?

    source_pull_request_number.present?
  end

  def manual?
    trigger_type == "manual"
  end

  def automatic?
    trigger_type == "automatic"
  end

  def queue_priority_rank
    self[:queue_priority] || QUEUE_PRIORITIES.dig(queue_priority_tier, :indicator)&.-(1) || Float::INFINITY
  end

  def queue_goal_priority_rank
    self[:goal_priority] || (QUEUE_GOAL_PRIORITY_GOALS.include?(goal) ? 0 : 1)
  end

  private :queue_priority_rank, :queue_goal_priority_rank

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
    return true if status.in?(%w[timeout token_budget_exceeded auth_expired rate_limited])
    return false if pre_runner_infra_failure?

    OPERATIONAL_FAILURE_KEYWORDS.any? do |keyword|
      error_message.to_s.downcase.include?(keyword.downcase)
    end
  end

  # Returns true when this run failed due to a purely transient provider or
  # infrastructure outage that will resolve on its own once capacity returns.
  # Unlike other operational failures, these do not warrant human escalation
  # because a human reviewer cannot fix them — automated retries will succeed
  # after the provider recovers.
  #
  # Covers: runner rate limits / circuit-open / unavailable (rate_limited
  # status) and provider/runner exhaustion errors in failed runs.
  def provider_unavailable?
    return true if status == "rate_limited"
    return false unless operational_failure?

    msg = error_message.to_s.downcase
    PROVIDER_UNAVAILABLE_KEYWORDS.any? { |keyword| msg.include?(keyword.downcase) }
  end

  # Returns true when the run failed due to infrastructure issues before the
  # LLM runner was ever reached (e.g., Docker pull failure, DNS resolution
  # error). These should not count toward the operational failure escalation
  # breaker since the agent never had a chance to work.
  def pre_runner_infra_failure?
    return false unless status == "failed"
    return false if tokens_input.to_i > 0
    return false if final_runner.present?

    msg = error_message.to_s
    PRE_RUNNER_INFRA_KEYWORDS.any? { |keyword| msg.downcase.include?(keyword.downcase) }
  end

  def infra_failure?
    return false unless PRE_MODEL_FAILURE_STATUSES.include?(status)
    return false if tokens_input.to_i > 0

    msg = error_message.to_s
    INFRA_FAILURE_KEYWORDS.any? { |keyword| msg.downcase.include?(keyword.downcase) }
  end

  # Returns true when the run failed because GitHub rejected a push for a
  # permission the authenticating GitHub App installation token lacks (most
  # commonly a change under .github/workflows/ that needs the workflows
  # permission). Such a rejection is permanent — it fails identically on every
  # retry until the App's permissions change or a PAT push fallback is enabled —
  # so callers treat it as terminal and stop re-enqueuing the issue.
  def push_permission_rejection?
    return false unless status == "failed"

    msg = error_message.to_s
    PUSH_PERMISSION_REJECTION_KEYWORDS.any? { |keyword| msg.include?(keyword) }
  end

  def total_tokens
    tokens_input.to_i + tokens_output.to_i
  end

  # @spec EXEC-USAGE-006
  # Sum of LLM cost (cost_cents) and infra cost (infra_cost_cents).
  # Both columns are denormalized on the run, so this is a single-row
  # calculation without joining execution_usages.
  def total_cost_cents
    cost_cents.to_i + infra_cost_cents.to_i
  end

  # @spec EXEC-USAGE-006
  # Whether this run has any infra usage recorded.
  def has_execution_usage?
    execution_usages.exists?
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

  def token_budget_exceeded?
    status == "token_budget_exceeded"
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

  # Per-run input-token budget. When input tokens exceed this *and* output
  # stays below #effective_token_budget_progress_floor, the run is terminated
  # early as "token_budget_exceeded" rather than burning through the full prompt.
  # Resolution: project override → provider (runner) threshold → global default.
  # See issue #2511.
  def effective_token_budget
    return @effective_token_budget if defined?(@effective_token_budget)

    @effective_token_budget =
      project.token_budget_max_input_tokens ||
      runner&.effective_no_progress_thresholds&.dig("min_input_tokens") ||
      Runner::DEFAULT_NO_PROGRESS_THRESHOLDS.fetch("min_input_tokens")
  end

  # Output-token floor below which a run is considered "not making progress".
  # A run at/above this floor is never terminated for budget exhaustion.
  def effective_token_budget_progress_floor
    return @effective_token_budget_progress_floor if defined?(@effective_token_budget_progress_floor)

    @effective_token_budget_progress_floor =
      runner&.effective_no_progress_thresholds&.dig("max_output_tokens") ||
      Runner::DEFAULT_NO_PROGRESS_THRESHOLDS.fetch("max_output_tokens")
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

      return self if running? && started_at.present?

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

  def cancel!(error: nil)
    with_lock do
      reload
      if finished?
        false
      else
        attributes = {
          status: "cancelled",
          completed_at: Time.current,
          duration_seconds: duration
        }
        attributes[:error_message] = error if error
        update!(attributes)
      end
    end
  end

  # Terminates the run as a terminal state. Defaults to "timeout" but accepts a
  # distinct `status:` (e.g. "token_budget_exceeded") so guardrail terminations
  # remain distinguishable in metrics from generic timeouts.
  def timeout!(error: nil, status: "timeout", guardrail_violation_type: nil, guardrail_context: nil)
    with_lock do
      reload
      if finished?
        false
      else
        attributes = {
          status: status,
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

  # True when the run is parked in "rate_limited" with a recovery time set,
  # meaning it is awaiting an in-place re-queue (StaleRunDetectorJob) rather than
  # being terminally failed. Callers use this to avoid arming issue-level
  # re-enqueue (which would mint a duplicate, superseding run) while the existing
  # run is simply waiting for a runner to free up.
  def recoverable_rate_limited?
    rate_limited? && rate_limited_until.present?
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
  # These delegate to AgentRuns::Execute and PromptAssembly services.

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

  # Builds a prompt for this run's issue using PromptAssembly.
  #
  # For create_pr runs the prompt is assembled from ordered, provenance-tracked
  # section providers via {PromptAssembly::BuildIssuePrompt}. The assembly
  # result is memoized so {#effective_prompt} can record provenance and avoid
  # double-injecting marketplace content.
  #
  # @spec PROMPT-ASSEMBLY-014
  #
  # @return [String, nil] The built prompt, or nil if no issue is attached
  def prompt_for_issue
    return nil unless issue

    @prompt_assembly_result = PromptAssembly::BuildIssuePrompt.call(
      issue: issue,
      project: project,
      github_client: project.github_token&.client,
      agent_run: self
    )
    @prompt_assembly_result.text
  end

  # Returns the agent's stdout output joined as a single string.
  # Strips the raw JSON envelope when stdout is a Claude CLI --output-format json
  # response, extracting just the assistant's result text.
  #
  # For a successful run, stale error events from a superseded fallback attempt
  # are ignored so the summary reflects the winning attempt's output.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The agent summary text (may be empty)
  def agent_summary(limit: 500)
    normalized_agent_output(logs_text(log_type: "stdout", limit: limit))
  end

  # Normalizes caller-supplied stdout through the run's provider parser.
  # Callers that already selected the relevant log window use this to avoid a
  # second query with different ordering or truncation semantics.
  def normalized_agent_output(raw_stdout, succeeded: successful?)
    extract_text_from_stdout(raw_stdout, succeeded: succeeded)
  end

  # Returns the agent's output, preferring stdout but falling back to stderr.
  # Useful for issue-goal runs where agents may write drafted content to stderr.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The best available agent output (may be empty)
  def agent_summary_with_stderr_fallback(limit: 500)
    summary = extract_text_from_stdout(logs_text(log_type: "stdout", limit: limit), succeeded: successful?)
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
  # When the create_pr path produced a PromptAssembly result that already
  # includes marketplace content, the marketplace injection is skipped to
  # avoid duplication. Section provenance is persisted to external_metadata.
  #
  # @return [String, nil] The prompt to send to the agent
  def effective_prompt
    base = custom_prompt.presence || prompt_for_goal

    unless prompt_assembly_marketplace_handled?
      if agent_run_marketplace_entries.exists?
        runner_key = runner&.runner_key || RunnerSupport.runner_key_for_agent_type(agent_type)
        base = MarketplaceEntries::InjectIntoPrompt.call(agent_run: self, prompt: base, provider_key: runner_key)
      end
    end

    persist_prompt_assembly_provenance!
    base
  end

  # Whether the PromptAssembly result already included marketplace content,
  # so {#effective_prompt} can skip the separate injection step.
  #
  # @spec PROMPT-ASSEMBLY-014
  def prompt_assembly_marketplace_handled?
    @prompt_assembly_result&.sections&.any? { |section| section.key == :marketplace_attachments }
  end

  # Persists section provenance from the memoized PromptAssembly result into
  # external_metadata. Uses update_columns to avoid triggering lifecycle
  # callbacks — this is a metadata-only audit record, not a state change.
  #
  # @spec PROMPT-ASSEMBLY-014
  def persist_prompt_assembly_provenance!
    return unless @prompt_assembly_result
    return unless persisted?

    current = external_metadata.is_a?(Hash) ? external_metadata : {}
    update_columns(
      external_metadata: current.merge(ISSUE_PROMPT_ASSEMBLY_KEY => @prompt_assembly_result.provenance)
    )
  end

  PROMPT_ASSEMBLY_KEY = "prompt_assembly"
  ISSUE_PROMPT_ASSEMBLY_KEY = "issue_prompt_assembly"
  ISSUE_ANALYSIS_DIAGNOSTICS_KEY = "issue_analysis_diagnostics"
  RUNTIME_IMAGE_KEY = "runtime_image"
  PROMPT_BUILDER_KEY = "prompt_builder"
  SERVICE_DECLARATIONS_KEY = "service_declarations"

  # Persists prompt-assembly provenance (digest + section list) on the run so
  # configuration bundles and run metadata can fingerprint exactly which
  # sections reached the agent. Bodies are never included — only keys, sources,
  # trust levels, and inclusion reasons.
  #
  # @spec PROMPT-ASSEMBLY-010
  def record_prompt_assembly!(provenance)
    return if provenance.blank?

    metadata = (external_metadata.is_a?(Hash) ? external_metadata.dup : {})
    metadata[PROMPT_ASSEMBLY_KEY] = provenance
    update!(external_metadata: metadata)
  end

  def prompt_assembly_provenance
    external_metadata.is_a?(Hash) ? external_metadata[PROMPT_ASSEMBLY_KEY] : nil
  end

  def issue_prompt_assembly_provenance
    external_metadata.is_a?(Hash) ? external_metadata[ISSUE_PROMPT_ASSEMBLY_KEY] : nil
  end

  def issue_analysis_diagnostics
    external_metadata.is_a?(Hash) ? external_metadata[ISSUE_ANALYSIS_DIAGNOSTICS_KEY] : nil
  end

  # Replace the per-phase diagnostics blob rather than merging it. Each
  # `record_issue_analysis_diagnostics!` call describes the currently active
  # phase (running/completed/failed) on the analyze_issue run, and the
  # timeout-path reader (`issue_analysis_timeout_message`) reports only the
  # last phase's data. Merging would let failure-only keys from a prior phase
  # (`error_class`, `error_message`) survive into a later `running` write,
  # leaving diagnostics that describe the new phase but still carry the
  # previous attempt's error details.
  def record_issue_analysis_diagnostics!(attributes)
    metadata = external_metadata.is_a?(Hash) ? external_metadata.deep_dup : {}
    metadata[ISSUE_ANALYSIS_DIAGNOSTICS_KEY] = attributes.deep_stringify_keys
    persist_external_metadata_update!(metadata)
  end

  def issue_analysis_timeout_message(base_message = "Activity task timed out")
    diagnostics = issue_analysis_diagnostics
    return base_message if diagnostics.blank?

    details = []
    details << (diagnostics["phase_label"].presence || diagnostics["phase_key"].to_s.tr("_", " "))
    details << "provider #{diagnostics['provider']}" if diagnostics["provider"].present?
    details << "attempt #{diagnostics['attempt']}" if diagnostics["attempt"].present?
    details << "budget #{diagnostics['budget_seconds']}s" if diagnostics["budget_seconds"].present?

    return base_message if details.empty?

    "#{base_message} (last known analyze_issue phase: #{details.join(' · ')})"
  end

  def prompt_assembly_digest
    prompt_assembly_provenance&.dig("digest")
  end

  def record_runtime_image_selection!(selection)
    # @spec IMMUTABLE-IMAGE-002
    return if selection.blank?

    metadata = external_metadata.is_a?(Hash) ? external_metadata.dup : {}
    metadata[RUNTIME_IMAGE_KEY] = selection
    persist_external_metadata_update!(metadata)
  end

  def persist_external_metadata_update!(metadata)
    if persisted?
      update_columns(external_metadata: metadata)
    else
      self.external_metadata = metadata
    end
  end
  private :persist_external_metadata_update!

  def runtime_image_selection
    external_metadata.is_a?(Hash) ? external_metadata[RUNTIME_IMAGE_KEY] : nil
  end

  def record_service_declarations!(declarations, container_ids:)
    return if declarations.blank?

    metadata = external_metadata.is_a?(Hash) ? external_metadata.dup : {}
    metadata[SERVICE_DECLARATIONS_KEY] = {
      "container_ids" => Array(container_ids),
      "declarations" => ExecutionRunners.json_value(declarations)
    }
    persist_external_metadata_update!(metadata)
  end

  def service_declaration_snapshot
    return unless external_metadata.is_a?(Hash)

    snapshot = external_metadata[SERVICE_DECLARATIONS_KEY]
    snapshot.is_a?(Hash) ? snapshot : nil
  end

  # Clears any runtime image selection previously recorded on this run. Used
  # on the fresh-reprovision path so a replacement container records the
  # current catalog resolution rather than the dead container's digest — the
  # complement to Provision#recorded_run_selection, which reuses the recorded
  # selection across reconnects (RDR-059 / IMMUTABLE-IMAGE-002).
  def clear_runtime_image_selection!
    return unless external_metadata.is_a?(Hash) && external_metadata.key?(RUNTIME_IMAGE_KEY)

    metadata = external_metadata.dup
    metadata.delete(RUNTIME_IMAGE_KEY)

    update_columns(external_metadata: metadata)
  end

  def record_prompt_builder!(builder)
    metadata = (external_metadata.is_a?(Hash) ? external_metadata.dup : {})
    metadata[PROMPT_BUILDER_KEY] = builder.to_s
    update!(external_metadata: metadata)
  end

  def prompt_builder
    external_metadata.is_a?(Hash) ? external_metadata[PROMPT_BUILDER_KEY] : nil
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

  def resource_profile_runner_key
    effective_runner.presence
  end

  def resource_profile_oom?
    return true if error_message.to_s.match?(AgentRunResourceProfile.oom_message_pattern)

    Array(runners_attempted).any? do |attempt|
      attempt["error_message"].to_s.match?(AgentRunResourceProfile.oom_message_pattern)
    end
  end

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

  # True when this run was enqueued without a pinned runner, so the queue
  # processor should resolve a runnable runner at dequeue time
  # (Runner-agnostic queue; see #2563). Runs created through the
  # runner-resolving enqueue paths pre-#2563 have a non-nil runner_id and
  # are treated as pinned.
  def runner_unbound?
    runner_id.nil?
  end
  alias_method :provider_unbound?, :runner_unbound?

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
                            resolution_source: nil, output_chars: nil)
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
    attempt["output_chars"] = output_chars if output_chars.present?

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

  # Provisions the execution environment for this agent run.
  #
  # Idempotent across retries: if a previous attempt already recorded a live
  # container (e.g. a Temporal activity retry after a worker crash mid-provision),
  # it is reused instead of provisioning a duplicate. A recorded container that
  # has since died or disappeared is reconciled (cleaned up and cleared) before
  # a fresh one is provisioned, preventing orphaned-container leaks on retry.
  #
  # When worktree_path is blank, an empty workspace directory is auto-created
  # for in-container git clone. When set, the existing path is bind-mounted.
  #
  # @param options [Hash] Override default container options
  # @return [Containers::Provision::Result] Result with container_id on success
  # @raise [Containers::Provision::ProvisionError] When container creation fails
  def provision_execution_environment(restart_provisioning_cycle: false, **options)
    networking_policy = nil
    if authority_grants.blank? || authority_grants["grants"].blank?
      networking_policy = Containers::Provision.networking_policy_for(
        agent_run: self, project: project
      )
      persist_execution_authority_grants!(networking_policy: networking_policy)
    end

    if execution_runner_enabled?
      return provision_via_runner(
        networking_policy: networking_policy,
        restart_provisioning_cycle: restart_provisioning_cycle,
        **options
      )
    end

    return reuse_or_reconcile_container(restart_provisioning_cycle: restart_provisioning_cycle, **options) if container_id.present?

    # Deliberately not threading networking_policy through here: on the
    # direct-provision path (execution_runner disabled) there is no runner to
    # own the network/firewall translation, so Containers::Provision must
    # perform its own NetworkPolicy.ensure_network!/apply_firewall_rules
    # side effects. Passing a policy would make it skip those (see
    # Containers::Provision#ensure_network!/#apply_network_restrictions!),
    # silently dropping egress isolation for first provisions.
    provision_new_container(restart_provisioning_cycle: restart_provisioning_cycle, **options)
  end

  # Compatibility shim for legacy container-named callers.
  def provision_container(**options)
    provision_execution_environment(**options)
  end

  # Executes a command in the provisioned execution environment.
  #
  # @param command [String, Array<String>] Command to execute
  # @param timeout [Integer] Timeout in seconds (default from container options)
  # @param stream [Boolean] Whether to stream output to agent logs
  # @return [Containers::Provision::Result] Result with stdout, stderr, exit_code
  # @raise [Containers::Provision::ProvisionError] When container not provisioned
  # @raise [Containers::Provision::TimeoutError] When command times out
  def execute_in_execution_environment(command, timeout: nil, stream: true, env: {}, preparation: nil)
    if @current_handle
      return execute_via_runner(command, timeout: timeout, env: env, preparation: preparation)
    end

    ensure_container_service!
    @container_service.execute(command, timeout: timeout, stream: stream, env: env, preparation: preparation)
  end

  # Compatibility shim for legacy container-named callers.
  def execute_in_container(command, timeout: nil, stream: true, env: {}, preparation: nil)
    execute_in_execution_environment(
      command,
      timeout: timeout,
      stream: stream,
      env: env,
      preparation: preparation
    )
  end

  # Cleans up the provisioned execution environment.
  #
  # Always attempts to remove the agent run's named workspace volume as a
  # safety net, even when no container_id is recorded — a worker killed
  # mid-provision (e.g. by Thread#kill on activity cancellation) may have
  # created the volume via prepare_workspace! without ever persisting
  # container_id. cleanup_orphaned_workspace_volume is a no-op when no
  # such volume exists or when worktree_path is set (bind-mount flows).
  #
  # @param force [Boolean] Force kill if container doesn't stop gracefully
  # @param preserve_workspace_volume [Boolean] Skip removing the shared
  #   workspace volume — see Containers::Provision#cleanup for why a caller
  #   tearing down a stale container reference needs this.
  # @return [void]
  def cleanup_execution_environment(force: false, preserve_workspace_volume: false)
    # Snapshot up front: a caller operating on a stale id (e.g.
    # ExecutionControlParkCleanupJob, which assigns a park-time snapshot
    # before calling this method) must tear down *that* container without
    # the row write below clobbering a container_id the run may have picked
    # up in the meantime via redispatch.
    target_container_id = container_id
    target_runner_handle = runner_handle.presence
    rehydrate_runner_handle_for_cleanup(target_runner_handle)
    target_container_host = workspace_volume_host

    # Safety net for a worker killed mid-provision: the workspace volume
    # may exist with no container_id to drive a normal cleanup. Run before
    # the early-return so it covers all paths (worktree-based runs are no-ops).
    cleanup_orphaned_workspace_volume if target_container_id.blank? && @container_service.nil? && @current_handle.nil?

    return if target_container_id.blank? && @container_service.nil? && @current_handle.nil?

    ExecutionResource.schedule_cleanup_for!(agent_run: self)

    if Containers::PoolManager.cleanup_claimed_container(agent_run: self, force: force)
      @container_service = nil
      @current_handle = nil
      clear_execution_environment_reference_if_unchanged!(target_container_id)
      ExecutionResource.mark_cleaned_for!(agent_run: self)
      record_execution_usage_after_cleanup!(container_id: target_container_id, container_host: target_container_host)
      return
    end

    if @current_handle
      cleanup_via_runner(
        force: force,
        expected_container_id: target_container_id,
        expected_runner_handle: target_runner_handle
      )
    else
      ensure_container_service!
      @container_service.cleanup(force: force, preserve_workspace_volume: preserve_workspace_volume)
      @container_service = nil
      clear_execution_environment_reference_if_unchanged!(target_container_id)
    end
    ExecutionResource.mark_cleaned_for!(agent_run: self)
    record_execution_usage_after_cleanup!(container_id: target_container_id, container_host: target_container_host)
  rescue Containers::Provision::Error, ExecutionRunners::Error => e
    ExecutionResource.record_cleanup_failure_for!(agent_run: self, error: e)
    # Container may already be gone; clear the reference anyway
    @container_service = nil
    @current_handle = nil
    clear_execution_environment_reference_if_unchanged!(target_container_id, also_clear: { runner_handle: nil })
    # The container is gone but the workspace volume may still exist.
    # Provision#cleanup would normally handle this in its ensure block,
    # but we never reached it, so clean up the volume directly. Skip it
    # when preserve_workspace_volume is set (redispatch race): the volume
    # may already be in use by a container that redispatch just claimed.
    cleanup_orphaned_workspace_volume unless preserve_workspace_volume
  end

  # Compatibility shim for legacy container-named callers.
  def cleanup_container(force: false, preserve_workspace_volume: false)
    cleanup_execution_environment(force: force, preserve_workspace_volume: preserve_workspace_volume)
  end

  # Maps AgentRun::STATUSES to ExecutionUsage::TERMINATION_REASONS. Statuses
  # with no explicit entry (queued, running, paused, rate_limited, retried)
  # are recorded as "evicted" by record_execution_usage!'s fallback — the
  # cloud resource was reclaimed independent of the run reaching a normal
  # terminal outcome (e.g. ExecutionControlParkCleanupJob tearing down a
  # parked run's environment).
  EXECUTION_TERMINATION_REASON_BY_STATUS = {
    "completed" => "completed",
    "no_output" => "completed",
    "cancelled" => "cancelled",
    "timeout" => "timed_out",
    "failed" => "failed",
    "token_budget_exceeded" => "failed",
    "auth_expired" => "failed"
  }.freeze

  # Records the per-run infrastructure usage/cost summary once the cloud
  # resource backing this run has actually been torn down. Used by the
  # primary cleanup path and the fallback janitors so delayed cleanup still
  # closes out billable lifetime accounting exactly once per run.
  # @spec EXEC-USAGE-009
  def record_execution_usage_after_cleanup!(container_id:, container_host:, terminated_at: Time.current)
    record_execution_usage!(container_id: container_id, container_host: container_host, terminated_at: terminated_at)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn(
      message: "agent_execution.record_execution_usage_persist_failed",
      agent_run_id: id,
      error_class: e.class.name,
      error: e.message
    )
    nil
  end

  def record_execution_usage!(container_id:, container_host:, terminated_at:)
    return if provisioning_started_at.blank? || container_host.blank?

    resources = Capacity::RequestedResources.for_agent_run(self)
    AgentRuns::RecordExecutionUsage.call(
      agent_run: self,
      runner_backend: normalized_execution_usage_runner_backend(container_host),
      provider_resource_id: container_id,
      provisioned_at: provisioning_started_at,
      execution_started_at: started_at,
      completed_at: completed_at,
      terminated_at: terminated_at,
      requested_cpu_cores: execution_usage_cpu_cores(resources),
      requested_memory_mib: execution_usage_memory_mib(resources),
      requested_disk_gb: execution_usage_disk_gb(resources),
      termination_reason: EXECUTION_TERMINATION_REASON_BY_STATUS.fetch(status, "evicted")
    )
  end
  private :record_execution_usage!

  def restamp_provisioning_cycle!
    self.provisioning_started_at = Time.current
    return unless external_metadata.is_a?(Hash)

    self.external_metadata = external_metadata.merge("provisioning_started_at" => provisioning_started_at.iso8601)
  end
  private :restamp_provisioning_cycle!

  def persisted_provisioning_cycle_attributes
    attributes = instance_variable_get(:@attributes)
    return {} unless attributes.respond_to?(:fetch_value)

    {
      provisioning_started_at: provisioning_started_at,
      external_metadata: external_metadata
    }
  end
  private :persisted_provisioning_cycle_attributes

  def normalized_execution_usage_runner_backend(container_host)
    container_host.to_s.truncate(64)
  end
  private :normalized_execution_usage_runner_backend

  # Docker CPU quota is expressed in units where 100_000 = 1 CPU core
  # (Containers::Provision's CpuPeriod) — convert back to cores.
  def execution_usage_cpu_cores(resources)
    (resources[:cpu_quota].to_f / 100_000.0).round(3)
  end
  private :execution_usage_cpu_cores

  def execution_usage_memory_mib(resources)
    (resources[:memory_bytes].to_f / 1.megabyte).round
  end
  private :execution_usage_memory_mib

  def execution_usage_disk_gb(resources)
    (resources[:disk_bytes].to_f / 1.gigabyte).round
  end
  private :execution_usage_disk_gb

  # Clears persisted execution-environment references only if container_id
  # still matches the environment this method just tore down. A run cleaned up
  # from a stale snapshot (see cleanup_execution_environment above) may have
  # already been re-dispatched to a different environment by the time teardown
  # finishes; an unconditional write here would silently wipe the new
  # environment's id out from under the run that is now using it.
  def clear_execution_environment_reference_if_unchanged!(expected_container_id, also_clear: {})
    updates = also_clear.merge(container_id: nil, container_host: nil)
    self.class.where(id: id, container_id: expected_container_id).update_all(updates)
    assign_attributes(updates) if container_id == expected_container_id
  end

  # Persists the id of an execution environment that provisioning created but
  # never recorded, so a later cleanup activity can tear it down.
  #
  # Two paths:
  # 1. Runner path: when a runner provisioned the environment and the handle
  #    is in memory (+@current_handle+) but not yet persisted, persists
  #    +runner_handle+ alongside +container_id+ and +container_host+
  #    (RDR-054). Driven by the presence of +@current_handle+, not the live
  #    +execution_runner_enabled?+ flag, so a handle survives a flag flip
  #    before +Thread#kill+ discards it.
  # 2. Legacy path: recovers the in-flight Docker container from
  #    +@container_service+ when a provisioning worker was forcibly
  #    terminated before the container id could be recorded.
  #
  # Containers::Provision#provision creates the Docker container at
  # +@container = create_container+ but only records it here once the full
  # provision (start + credential seeding) succeeds. If the provisioning
  # worker is forcibly terminated in that window — e.g. ProvisionContainerActivity
  # falls back to Thread#kill for a worker stuck in an uninterruptible Docker
  # call, which bypasses Containers::Provision's SignalException cleanup — the
  # created container is orphaned with no recorded container_id, and
  # CleanupContainerActivity could previously only reclaim its workspace
  # volume by name. Recording the in-flight container here closes that leak.
  #
  # No-op when a container_id is already recorded or no in-flight environment
  # exists (e.g. the worker was killed before create_container). Returns the
  # recorded environment identifier, or nil.
  def recover_in_flight_execution_environment!
    return if container_id.present?

    # Runner path: persist the in-flight handle before Thread#kill discards it.
    if @current_handle && runner_handle.blank?
      handle_hash = @current_handle.to_storage
      self.class.where(id: id, runner_handle: nil)
        .update_all(runner_handle: handle_hash, container_id: @current_handle.identifier,
                    container_host: @current_handle.host)
      self.runner_handle = handle_hash
      self.container_id = @current_handle.identifier
      self.container_host = @current_handle.host
      ExecutionResource.track_environment!(agent_run: self, handle: @current_handle)
      Rails.logger.info(
        message: "container_manager.recovered_in_flight_runner_handle",
        agent_run_id: id,
        runner_type: @current_handle.runner_type.to_s,
        identifier: @current_handle.identifier,
        container_host: @current_handle.host
      )
      return @current_handle.identifier
    end

    # Legacy path: recover the in-flight Docker container.
    service = @container_service
    container = service&.container
    return unless container

    host = service.backend.container_host_for(container)
    self.class.where(id: id, container_id: nil)
      .update_all(container_id: container.id, container_host: host)
    self.container_id = container.id
    self.container_host = host
    ExecutionResource.track_environment!(agent_run: self, identifier: container.id, host: host)
    Rails.logger.info(
      message: "container_manager.recovered_in_flight_container",
      agent_run_id: id,
      container_id: container.id,
      container_host: host
    )
    container.id
  end

  # Compatibility shim for legacy container-named callers.
  def recover_in_flight_container!
    recover_in_flight_execution_environment!
  end

  # Executes a block with a provisioned execution environment, ensuring cleanup.
  #
  # @param options [Hash] Override default container options
  # @yield [self] The agent run with provisioned container
  # @return [Object] The return value of the block
  def with_execution_environment(**options, &)
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

  # Compatibility shim for legacy container-named callers.
  def with_container(**options, &)
    with_execution_environment(**options, &)
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

  # @spec EXECUTION-AUTHORITY-001
  def execution_authority_grants(networking_policy: nil)
    resolved_policy = resolve_networking_policy(networking_policy)
    ExecutionRunners::AuthorityGrantSet.from_agent_run(self, networking_policy: resolved_policy)
  end

  # @spec EXECUTION-AUTHORITY-001
  def persist_execution_authority_grants!(networking_policy: nil)
    resolved_policy = resolve_networking_policy(networking_policy)
    grant_set = execution_authority_grants(networking_policy: resolved_policy)
    update!(authority_grants: grant_set.to_storage)
    ExecutionAuditEvents::Lifecycle.record(
      event_name: "execution.credential_classes_granted",
      actor_id: "agent_run.persist_execution_authority_grants",
      agent_run: self,
      networking_policy: resolved_policy,
      metadata: {
        grant_kinds: Array(grant_set.grants).map { |grant| grant["kind"] }
      }
    )
    ExecutionAuditEvents::Lifecycle.record(
      event_name: "execution.network_policy_granted",
      actor_id: "agent_run.persist_execution_authority_grants",
      agent_run: self,
      networking_policy: resolved_policy,
      metadata: {
        grant_kinds: Array(grant_set.grants).map { |grant| grant["kind"] }
      }
    )
    grant_set
  end

  private

  def resolve_networking_policy(networking_policy)
    networking_policy || Containers::Provision.networking_policy_for(agent_run: self, project: project)
  end

  # ── runner shim helpers (RDR-054) ──────────────────────────────

  def execution_runner_enabled?
    project.is_a?(Project) && FeatureFlags.enabled?(:execution_runner_enabled, project: project)
  end

  # Provisions a container through the execution runner interface.
  # Reuses an existing recorded container (Temporal retry safety) before
  # trying the warm pool, then delegating to the runner for a fresh
  # provision. Pooling is not yet modeled by the runner interface (RunSpec
  # has no pool-awareness), so this mirrors provision_new_container's
  # pool-first behavior directly rather than pushing it into
  # LocalDockerRunner#provision, keeping the pool/replenish contract in one
  # place until pooling is designed into the runner contract itself.
  #
  # When a +runner_handle+ is already persisted (a prior provision via the
  # runner that survived a worker restart), recovery goes through
  # +reuse_or_reconcile_via_runner+ — the runner-level reconnect path —
  # rather than the Docker-specific +reuse_or_reconcile_container+.
  # +networking_policy:+ is optional so the recovery path
  # (+reuse_or_reconcile_via_runner+ recursing back here after a stale
  # handle is cleaned up) can re-enter without threading the policy through.
  # Deriving it here keeps the manifest accurate for subscription-auth /
  # direct-outbound recovery rather than defaulting to proxy_mode when a
  # +nil+ policy falls through (RDR-058, RDR-054).
  def provision_via_runner(networking_policy: nil, restart_provisioning_cycle: false, **options)
    return reuse_or_reconcile_via_runner(restart_provisioning_cycle: restart_provisioning_cycle, **options) if runner_handle.present?

    return reuse_or_reconcile_container(restart_provisioning_cycle: restart_provisioning_cycle, **options) if container_id.present?

    planned_container_host = options.delete(:container_host)
    pool_host_scope = planned_container_host.presence || container_host.presence

    # Resolved up front (not left to RunSpec.from_agent_run) so a warm-pool
    # claim honors the same owner-setting/profile timeout precedence as a
    # fresh provision: PoolManager#acquire only forwards an explicitly
    # supplied timeout_seconds and would otherwise silently fall back to the
    # 3600s default for pooled runs (CONTAINER-RUNTIME-027).
    options[:timeout_seconds] = ExecutionRunners::RunSpec.resolve_timeout_seconds(self, options)

    # Restamped before the pooled claim (not just the fresh-provision branch
    # below) so a reprovision that claims a warm container still starts a new
    # cycle key. Otherwise the pooled container's lifetime would be recorded
    # under the torn-down machine's provisioning_started_at and silently
    # dropped when AgentRuns::RecordExecutionUsage matches the already-closed
    # cycle (EXEC-USAGE-011).
    restamp_provisioning_cycle! if restart_provisioning_cycle

    pooled_result = acquire_pooled_container(pool_host_scope: pool_host_scope, **options)
    return pooled_result if pooled_result

    runner = ExecutionRunners.resolve_for(self)
    resolved_policy = networking_policy || Containers::Provision.networking_policy_for(
      agent_run: self, project: project
    )
    spec = ExecutionRunners::RunSpec.from_agent_run(self, networking_policy: resolved_policy, **options)
    @current_handle = runner.provision(spec: spec)
    update!(container_id: @current_handle.identifier, container_host: @current_handle.host,
            runner_handle: @current_handle.to_storage,
            **persisted_provisioning_cycle_attributes)
    ExecutionResource.track_environment!(agent_run: self, handle: @current_handle)
    PoolReplenishmentJob.perform_later(project_id)

    Containers::Provision::Result.success(
      container_id: @current_handle.identifier,
      container_host: @current_handle.host
    )
  end

  # Recovers a previously runner-provisioned environment from its persisted
  # +RunnerHandle+ after a Temporal activity retry (worker restart/failover).
  # Loads the handle from the DB, reconnects via the runner interface, and
  # either reuses a still-running environment or cleans up a dead/missing one
  # before provisioning fresh (RDR-054).
  # @spec CONTAINER-RUNTIME-016
  def reuse_or_reconcile_via_runner(**options)
    handle = ExecutionRunners::RunnerHandle.from_record(self)
    runner = ExecutionRunners.resolve_for(self)

    if handle && runner.running?(handle: handle)
      @current_handle = handle
      ExecutionResource.track_environment!(agent_run: self, handle: handle)
      Rails.logger.info(
        message: "container_manager.provision_reused_existing",
        agent_run_id: id,
        container_id: container_id
      )
      return Containers::Provision::Result.success(container_id: handle.identifier, container_host: handle.host)
    end

    if handle
      runner.cleanup(handle: handle, force: true)
      # The stale machine's lifetime must be closed out here, before
      # clear_runner_reference!/provision_via_runner's restamp moves
      # provisioning_started_at forward — cleanup_container never runs for
      # this handle, so this is the only place its usage gets recorded
      # (EXEC-USAGE-011).
      record_execution_usage_after_cleanup!(container_id: handle.identifier, container_host: handle.host)
    end
    clear_runner_reference!
    provision_via_runner(**options)
  end

  # Claims a warm container from the pool for this run, if one is
  # available and compatible. Shared by the legacy and runner-shim
  # provision paths so both stay pool-aware (RDR-054).
  #
  # @return [Containers::Provision::Result, nil] the pooled result on a
  #   successful claim, or nil when no warm container was claimed
  def acquire_pooled_container(pool_host_scope:, **options)
    pooled_result = Containers::PoolManager.new(project: project).acquire(
      agent_run: self,
      container_host: pool_host_scope,
      **options
    )
    return unless pooled_result&.success?

    @container_service = pooled_result[:service]
    update!(container_id: pooled_result[:container_id], container_host: pooled_result[:container_host])
    pooled_result
  end

  # Executes a command via the runner interface. Translates
  # ExecutionResult back to Provision::Result for caller compatibility.
  def execute_via_runner(command, timeout: nil, env: {}, preparation: nil)
    runner = ExecutionRunners.resolve_for(self)
    result = runner.start(
      handle: handle_with_env(env), command: command, timeout: timeout,
      startup_timeout: nil, idle_timeout: nil, abort_patterns: nil,
      preparation: preparation, heartbeat_path: nil
    )
    Containers::Provision::Result.success(
      stdout: result.stdout, stderr: result.stderr, exit_code: result.exit_code,
      container_running: result.environment_running
    )
  rescue ExecutionRunners::ProvisionError => e
    raise Containers::Provision::ProvisionError, e.message
  rescue ExecutionRunners::StartupTimeoutError => e
    raise Containers::Provision::StartupTimeoutError.new(e.message, diagnostics: e.diagnostics)
  rescue ExecutionRunners::IdleTimeoutError => e
    raise Containers::Provision::IdleTimeoutError.new(e.message, diagnostics: e.diagnostics)
  rescue ExecutionRunners::TimeoutError => e
    raise Containers::Provision::TimeoutError.new(e.message, diagnostics: e.diagnostics)
  rescue ExecutionRunners::ExecutionError => e
    raise Containers::Provision::ExecutionError.new(
      e.message, exit_code: e.exit_code, stdout: e.stdout, stderr: e.stderr
    )
  rescue ExecutionRunners::OutputAbortError => e
    raise Containers::Provision::OutputAbortError.new(
      e.message, matched_output: e.matched_output, source: e.source, detail: e.detail
    )
  end

  # Merges per-call env into @current_handle's metadata for a single #start
  # call. LocalDockerRunner#start only reads handle.metadata["environment"]
  # (the persistent service_environment captured at provision time), so
  # per-call env (e.g. HarnessExecutor's runner/auth env, KILOCODE_CONFIG_B64)
  # would otherwise be silently dropped instead of reaching the command.
  def handle_with_env(env)
    return @current_handle if env.blank?

    merged_environment = (@current_handle.metadata["environment"] || {}).merge(env)
    @current_handle.with(metadata: @current_handle.metadata.merge("environment" => merged_environment))
  end

  # Cleans up through the runner interface. Idempotent on missing resources.
  #
  # +expected_container_id+ mirrors
  # +clear_execution_environment_reference_if_unchanged!+ below: a
  # caller operating on a stale snapshot (e.g. ExecutionControlParkCleanupJob
  # tearing down a parked run's old environment) must not wipe out
  # container_id/runner_handle if the row has since been re-dispatched to a
  # different environment out from under it.
  def cleanup_via_runner(force: false, expected_container_id: nil, expected_runner_handle: nil)
    runner = ExecutionRunners.resolve_for(self)
    runner.cleanup(handle: @current_handle, force: force)
  rescue ExecutionRunners::ProvisionError
    nil
  ensure
    @current_handle = nil
    clear_execution_environment_reference_for_runner_if_unchanged!(
      expected_container_id,
      expected_runner_handle
    )
  end

  # Clears persisted container reference columns after a stale runner handle is
  # cleaned up, so a subsequent provision starts from a clean slate. Also
  # clears the recorded runtime image selection so a replacement container
  # records the current catalog resolution instead of inheriting provenance
  # from a container that no longer exists (RDR-059 / IMMUTABLE-IMAGE-002).
  # Uses +update_columns+ to bypass validations (the run may be in an
  # inconsistent state mid-reconciliation).
  def clear_runner_reference!
    @current_handle = nil
    update_columns(container_id: nil, container_host: nil, runner_handle: nil)
    clear_runtime_image_selection!
  end

  def rehydrate_runner_handle_for_cleanup(target_runner_handle)
    return if @current_handle || target_runner_handle.blank?

    @current_handle = ExecutionRunners::RunnerHandle.from_json(target_runner_handle)
  end

  def clear_execution_environment_reference_for_runner_if_unchanged!(expected_container_id, expected_runner_handle)
    updates = { container_id: nil, container_host: nil, runner_handle: nil }
    relation = self.class.where(id: id, container_id: expected_container_id, runner_handle: expected_runner_handle)
    relation.update_all(updates)

    return unless container_id == expected_container_id && runner_handle == expected_runner_handle

    assign_attributes(updates)
  end

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

  def external_execution_fields_are_consistent
    if execution_origin == "external"
      errors.add(:external_source_key, "is required for external execution") if external_source_key.blank?
      errors.add(:external_run_key, "is required for external execution") if external_run_key.blank?
      return
    end

    if external_source_key.present?
      errors.add(:external_source_key, "must be blank for paid-native runs")
    end

    if external_run_key.present?
      errors.add(:external_run_key, "must be blank for paid-native runs")
    end
  end

  # @spec CHAT-PR-PROPOSAL-007
  def extract_text_from_stdout(raw_stdout, succeeded: false)
    return raw_stdout if raw_stdout.blank?

    response = parse_structured_stdout(raw_stdout)
    if response&.error.present? && !succeeded
      return "Agent encountered an error: #{response.error}"
    end
    return response.output if response&.output.present?

    extract_text_from_multiline_json(raw_stdout, succeeded: succeeded) || raw_stdout
  end

  def extract_text_from_multiline_json(raw_stdout, succeeded: false)
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

    # Only surface a streaming-error summary when the run actually failed. A
    # successful run may still carry error JSON from a superseded fallback
    # attempt; surfacing it would mask the winning attempt's real output and
    # blank the PR description. See run 24528.
    if error_messages.present? && results.empty? && !succeeded
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
    ErrorMessageSanitizer.normalize_encoding(content.to_s)
  end

  def sanitize_runner_attempt_error_message(message)
    ErrorMessageSanitizer.call(text: message)
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
    elsif lid_planning_goal?
      prompt_for_lid_planning
    elsif enhance_issue_goal?
      prompt_for_enhance_issue
    elsif analyze_issue_goal?
      prompt_for_analyze_issue
    elsif create_feature_goal?
      # @spec CREATE-FEATURE-001
      prompt_for_create_feature
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

  def prompt_for_lid_planning
    # @spec LID-RUNS-002
    docs = []
    docs << { name: plan_doc_source } if plan_doc_source.present?
    if external_metadata.present?
      docs.concat(external_metadata.fetch("plan_docs", []))
    end

    Prompts::BuildForLidPlanning.call(
      project_name: project.full_name,
      project_description: Prompts::BuildForLidPlanning.project_description_for(project),
      plan_docs: docs,
      adoption: project.lid_mode.blank?
    )
  end

  def prompt_for_create_feature
    # @spec CREATE-FEATURE-001
    # @spec CREATE-FEATURE-002
    # The feature brief lives on external_metadata["feature_brief"] (see RDR-053
    # §2). has_prompt_source exempts create_feature, so the brief is the only
    # required input. Raise loudly when it is missing so the run surfaces the
    # bad input rather than dispatching an empty prompt.
    brief = external_metadata.is_a?(Hash) ? external_metadata["feature_brief"] : nil
    raise ArgumentError, "create_feature runs require external_metadata['feature_brief']" if brief.blank?

    Prompts::BuildForCreateFeature.call(
      project_name: project.full_name,
      full_name: project.full_name,
      feature_brief: brief,
      lid_mode: project.lid_mode
    )
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

  # Removes the named Docker workspace volume for this agent run if it exists.
  # No-op for worktree-based runs (they use bind mounts, not named volumes).
  # Delegates volume-name construction and deletion to the execution runner so
  # the domain model never builds Docker volume names (#3342).
  #
  # container_host is blank from claim time until a backend records a real
  # resource, so the owning host is resolved via workspace_volume_host — which
  # falls back to the planned admission host — to avoid probing the local
  # backend and leaking a remote volume when a worker died mid-provision.
  def cleanup_orphaned_workspace_volume
    return if worktree_path.present? # bind-mount runs don't use named volumes

    ExecutionRunners.resolve_for(self)
      .cleanup_workspace_reference(agent_run: self, host: workspace_volume_host)
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

  # Reuses an already-recorded container when it is still alive, making
  # provision_container safe to invoke again on a Temporal retry. A recorded
  # container that has died or been removed is reconciled away before a fresh
  # one is provisioned, so a retry never leaks a duplicate container.
  def reuse_or_reconcile_container(restart_provisioning_cycle: false, **options)
    service = reconnect_recorded_container_for_reuse

    if service&.container_running?
      @container_service = service
      ExecutionResource.track_environment!(agent_run: self)
      Rails.logger.info(
        message: "container_manager.provision_reused_existing",
        agent_run_id: id,
        container_id: container_id
      )
      return Containers::Provision::Result.success(container_id: container_id, container_host: container_host)
    end

    reconcile_stale_container!(service)
    provision_new_container(restart_provisioning_cycle: restart_provisioning_cycle, **options)
  end

  def reconnect_recorded_container_for_reuse
    Containers::Provision.reconnect(
      agent_run: self,
      container_id: container_id,
      worktree_path: worktree_path.presence
    )
  rescue Containers::Provision::ProvisionError => e
    raise unless recorded_container_missing?(e)

    # Recorded container is gone (manually removed / expired) — reconcile below.
    nil
  end

  def recorded_container_missing?(error)
    error.message.match?(/\AContainer .* not found\z/)
  end

  # Provisions a brand-new container when there is no existing container to
  # reuse. Tries the warm pool first, then falls back to a fresh provision.
  def provision_new_container(networking_policy: nil, restart_provisioning_cycle: false, **options)
    # RDR-048 (#2947): a caller (e.g. the queue processor) may know which
    # Docker host this run was admitted against before any container
    # resource exists. The container_host column on the run is intentionally
    # left nil until a backend creates or claims a real resource, so that
    # budget rejection, workflow-start failure, or warm-pool fallback do not
    # leave an ownership field pointing at a host that never owned the run.
    # Accept the planned host as a separate kwarg and thread it through
    # warm-pool scoping and backend selection; the persisted container_host
    # is only updated from the actual provision/pool result below.
    planned_container_host = options.delete(:container_host)
    pool_host_scope = planned_container_host.presence || container_host.presence

    # Restamped before the pooled claim (not just the fresh-provision branch
    # below) so a reprovision that claims a warm container still starts a new
    # cycle key. Otherwise the pooled container's lifetime would be recorded
    # under the torn-down machine's provisioning_started_at and silently
    # dropped when AgentRuns::RecordExecutionUsage matches the already-closed
    # cycle (EXEC-USAGE-011).
    restamp_provisioning_cycle! if restart_provisioning_cycle

    pooled_result = acquire_pooled_container(pool_host_scope: pool_host_scope, **options)
    return pooled_result if pooled_result

    backend_host = pool_host_scope.presence
    backend_host ||= container_host if container_host.present?

    @container_service = Containers::Provision.new(
      agent_run: self,
      worktree_path: worktree_path.presence,
      backend: Containers.backend_for(backend_host),
      networking_policy: networking_policy,
      **options
    )
    result = @container_service.provision
    if result.success?
      update!(container_id: result[:container_id], container_host: result[:container_host],
        **persisted_provisioning_cycle_attributes)
      ExecutionResource.track_environment!(
        agent_run: self,
        identifier: result[:container_id],
        host: result[:container_host]
      )
      PoolReplenishmentJob.perform_later(project_id)
    end
    result
  end

  # Cleans up a recorded container that is no longer usable (dead or missing)
  # so a fresh one can be provisioned. Handles both pooled and freshly
  # provisioned containers and guarantees the stale container_id is cleared.
  # Also clears the recorded runtime image selection so the replacement
  # container records the current catalog resolution instead of inheriting
  # provenance from a container that no longer exists (RDR-059 /
  # IMMUTABLE-IMAGE-002).
  def reconcile_stale_container!(service)
    @container_service = service
    cleanup_container(force: true)
  rescue StandardError => e
    Rails.logger.warn(
      message: "container_manager.reconcile_stale_failed",
      agent_run_id: id,
      container_id: container_id,
      error: e.message.to_s.truncate(500)
    )
  ensure
    @container_service = nil
    update_columns(container_id: nil) if container_id.present?
    clear_runtime_image_selection!
  end

  def self.host_scope_for(container_host)
    backend = Containers.backend_for(container_host)
    identifiers = backend.all_host_identifiers.map(&:to_s)
    # The COALESCE'd host expression in active_count_for_host is never NULL,
    # so a local backend matches its concrete identifiers plus the empty
    # string (legacy/blank rows whose planned host is also blank). A remote
    # backend matches only its concrete identifiers.
    backend.remote? ? identifiers : identifiers + [ "" ]
  rescue Containers::Backends::Resolver::UnknownBackendError
    [ container_host.to_s ]
  end
  private_class_method :host_scope_for

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def has_prompt_source
    # lid_planning derives its prompt from Prompts::BuildForLidPlanning, so it
    # needs no issue, custom prompt, or source PR.
    return if lid_planning_goal?
    # create_feature derives its prompt from Prompts::BuildForCreateFeature
    # and external_metadata["feature_brief"], so it needs no issue or source PR.
    return if create_feature_goal?
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

  # Maintains both project counter caches (`completed_agent_runs_count` and
  # `agent_runs_count`) so synthetic operational runs (live-preview provisioning)
  # never inflate user-facing run totals.
  #
  # `completed_agent_runs_count` is fully custom-managed here and skips synthetic
  # runs entirely. `agent_runs_count` is Rails' default `counter_cache: true`,
  # which auto-increments/decrements for every run including synthetic ones; the
  # correction below reverses that automatic adjustment for synthetic runs so
  # previews do not count toward the displayed "Runs" total.
  def update_agent_run_counter_caches
    completed_agent_runs_counter_deltas.each do |project_id, delta|
      Project.update_counters(project_id, completed_agent_runs_count: delta)
    end
    agent_runs_count_correction_deltas.each do |project_id, delta|
      Project.update_counters(project_id, agent_runs_count: delta)
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

  # True when a real (non-synthetic) agent run just reached a terminal state.
  # Synthetic operational runs (preview provisioning) finish via update too, but
  # they must not trigger terminal-state side effects, so they are excluded.
  def real_run_just_finished?
    just_finished? && !synthetic_operational_run?
  end

  def enqueue_quality_metrics_collection
    QualityMetricsCollectionJob.perform_later(id)
    HumanFeedbackCollectionJob.set(wait: 5.minutes).perform_later(id) if successful?
  end

  def enqueue_anomaly_detection
    AnomalyDetectionJob.perform_later(id)
  end

  def enqueue_resource_profile_refresh
    AgentRunResourceProfileRefreshJob.perform_later(id) if resource_profile_runner_key.present?
  end

  # Records the dispatch circuit breaker outcome for every terminal run,
  # regardless of which activity completed it. Successful half-open probes
  # can finish through CreatePullRequestActivity, CompleteIssueGoalActivity,
  # CompleteReviewGoalActivity, and other direct complete! paths — recording
  # here (instead of in a single activity) ensures half_open_success_count
  # is incremented for all of them so the breaker can recover.
  #
  # The agent_run_id is forwarded to the breaker so it can gate the
  # half_open counter on whether the run that just finished was the
  # explicit probe (set via mark_probe_dispatched!) or just a stale
  # in-flight run from before the circuit opened. Stale completions
  # must not affect half_open counters.
  #
  # Runs in a background job so the activity's commit chain does not
  # block on the (relatively expensive) provider-failure scan during
  # the burst-of-terminal-completions case the breaker exists to handle.
  def record_dispatch_circuit_breaker_outcome
    return unless final_runner.present?
    return unless project&.account
    # "completed"/"no_output" mean the provider ran fine; FAILURE_STATUSES
    # mean it did not. "cancelled"/"retried" are not real provider outcomes.
    success = successful? || status == "no_output"
    return unless success || status.in?(FAILURE_STATUSES)

    DispatchCircuitBreakerOutcomeJob.perform_later(
      account_id: project.account_id,
      success: success,
      agent_run_id: id
    )
  rescue => e
    Rails.logger.warn(
      message: "dispatch_circuit_breaker.record_outcome_error",
      agent_run_id: id,
      error_class: e.class.name,
      error_message: e.message.to_s.truncate(200)
    )
  end

  def just_started_running?
    previous_changes.key?("status") && status == "running"
  end

  # @spec TEMPORAL-ORCHESTRATION-005 — admission flips a run to running before
  # any container exists, so metrics seeding must also fire when provisioning
  # later assigns a container to an already-running run.
  def container_metrics_seed_due?
    return false unless container_id.present?

    just_started_running? || (previous_changes.key?("container_id") && running?)
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
    # Synthetic runs never reach a real "completed" outcome that should count.
    return {} if synthetic_operational_run?

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

  # Reverses Rails' default `counter_cache: true` adjustment of
  # `agent_runs_count` for synthetic runs only. Rails auto-increments on create,
  # auto-decrements on destroy, and moves the count on a project change for every
  # run; synthetic runs must not be counted, so each automatic delta is negated.
  # Real runs are left entirely to Rails' default counter cache (no delta here).
  def agent_runs_count_correction_deltas
    return {} unless synthetic_operational_run?

    deltas = Hash.new(0)
    if destroyed?
      deltas[project_id] += 1 if project_id.present?
    else
      previous_project_id = previous_changes.fetch("project_id", [ project_id, project_id ]).first
      deltas[previous_project_id] += 1 if previous_project_id.present?
      deltas[project_id] -= 1 if project_id.present?
    end
    deltas.reject { |_project_id, delta| delta.zero? }
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
    return false if synthetic_operational_run?

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

  def queue_preview_membership_changed?
    return false unless previous_changes.key?("status")

    from_status, to_status = previous_changes["status"]
    (from_status == "queued") != (to_status == "queued")
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
      LiveDashboardBroadcastJob.perform_later(
        project.account_id,
        id,
        refresh_queue_preview: queue_preview_membership_changed?
      )
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
