# frozen_string_literal: true

class AgentRun < ApplicationRecord
  MAX_PROVIDER_ATTEMPT_ERROR_MESSAGE_LENGTH = 500
  STATUSES = %w[queued pending running paused completed no_output failed cancelled timeout retried auth_expired rate_limited].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot aider gemini opencode kilocode api].freeze
  # analyze_issue is automation-only (triggered via Automation::Decision), not exposed in the manual run form.
  GOALS = %w[create_pr create_issue review enhance_issue analyze_issue].freeze
  TRIGGER_TYPES = %w[manual automatic].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  FINISHED_STATUSES = %w[completed no_output failed cancelled timeout retried auth_expired rate_limited].freeze
  FAILURE_STATUSES = %w[failed timeout auth_expired rate_limited].freeze
  TERMINAL_FAILURE_STATUSES = (FAILURE_STATUSES + %w[cancelled]).freeze
  QUALITY_EXCLUDED_STATUSES = %w[timeout auth_expired rate_limited].freeze

  OPERATIONAL_FAILURE_KEYWORDS = [
    "providers exhausted",
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

    arel_table.grouping(
      excluded_status.and(Arel::Nodes::Not.new(failed_operational))
    )
  end
  UNFINISHED_STATUSES = %w[queued pending running paused].freeze
  GUARDRAIL_VIOLATION_TYPES = %w[loop_detected token_limit cost_limit time_limit anomaly].freeze
  AUTO_PICK_BLOCKING_STATUSES = UNFINISHED_STATUSES
  TOKEN_LIMIT_STATUSES = %w[ok warning exceeded].freeze
  DEFAULT_MAX_TOKENS_PER_RUN = 10_000_000
  MAX_STALE_REQUEUES = 2
  MAX_STALE_SKIPS = 3
  STALE_PENDING_TIMEOUT = 15.minutes
  STALE_PAUSED_TIMEOUT = 2.hours
  STALE_RUNNING_GRACE_PERIOD = 10.minutes

  # Sentinel prefix written into AgentRun#error_message by `bin/rails dev:cleanup`
  # when it forcibly times out an in-flight run because the host process is being
  # restarted (e.g. `bin/setup --skip-server`). Code that observes a run failing
  # while marked with this prefix should treat the failure as caused by the
  # cleanup, not by the provider — in particular, do not increment provider
  # circuit-breaker counters on its behalf.
  STALE_CLEANUP_ERROR_PREFIX = "Marked stale on startup"

  STALE_DETECTOR_ERROR_PREFIX = "Stale run detected"

  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :prompt_version, optional: true
  belongs_to :provider, optional: true

  has_many :agent_run_logs, dependent: :destroy
  has_many :agent_run_phases, -> { order(:started_at, :id) }, dependent: :destroy
  has_many :container_pool_entries, dependent: :nullify
  has_many :token_usages, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy
  has_many :configuration_experiment_assignments, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all
  has_many :quality_metrics, dependent: :destroy
  has_one :worktree, dependent: :nullify
  has_one :model_selection, dependent: :destroy
  has_one :decision_record, dependent: :nullify
  has_many :agent_run_anomalies, dependent: :destroy
  has_many :knowledge_usage_stats, dependent: :destroy
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

  before_create :generate_proxy_token
  before_create :snapshot_mcp_servers

  after_commit :broadcast_project_updates, on: [ :create, :update ]
  after_commit :update_project_last_agent_run_at, on: :create
  after_commit :enqueue_quality_metrics_collection, on: :update, if: :just_finished?
  after_commit :enqueue_anomaly_detection, on: :update, if: :just_finished?
  after_commit :enqueue_container_metrics_collection, on: :update, if: :just_started_running?
  after_commit :enqueue_issue_goal_timeout_retry, on: :update, if: :just_timed_out_issue_goal?

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :goal, presence: true, inclusion: { in: GOALS }
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
  validates :final_provider, length: { maximum: 50 }
  validates :provider_switches, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :stale_requeue_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :stale_skip_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :token_limit_status, inclusion: { in: TOKEN_LIMIT_STATUSES }, allow_nil: true
  validates :guardrail_violation_type, inclusion: { in: GUARDRAIL_VIOLATION_TYPES }, allow_nil: true
  validates :priority_tier, inclusion: { in: Project::PRIORITY_TIERS }, allow_nil: true
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :provider_belongs_to_project_owner, if: -> { provider.present? }
  validate :has_prompt_source, on: :create
  validate :draft_review_round_tracking_is_consistent

  scope :by_status, ->(status) { where(status: status) }
  scope :queued, -> { where(status: "queued") }
  scope :pending, -> { where(status: "pending") }
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
  scope :finished, -> { where(status: FINISHED_STATUSES) }
  scope :recent, -> { order(created_at: :desc) }
  scope :started_before, ->(time) { where("started_at < ?", time) }
  scope :updated_before, ->(time) { where("updated_at < ?", time) }
  scope :stale_running, -> { running.started_before(stale_running_cutoff) }
  scope :stale_pending, -> { pending.updated_before(stale_pending_cutoff) }
  scope :stale_for_cleanup, -> { stale_running.or(stale_pending) }
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
  # normalize_provider_sql. Restricting to a whitelist prevents
  # accidental SQL injection if a future caller passes untrusted input.
  NORMALIZABLE_COLUMNS = [
    "agent_type",
    "final_provider",
    "NULLIF(final_provider, '')"
  ].freeze

  # SQL CASE expression that normalizes a column's value to its canonical
  # provider key (e.g. "claude_code" → "claude") so SQL aggregations match
  # Ruby logic.
  #
  # Derived from ProviderSupport.provider_key_for_agent_type for all known
  # AGENT_TYPES so that SQL and Ruby stay in sync if new aliases are added
  # or existing mappings change.
  #
  # +column+ must be one of NORMALIZABLE_COLUMNS to guard against SQL
  # injection. Defaults to "agent_type".
  def self.normalize_provider_sql(column = "agent_type")
    unless NORMALIZABLE_COLUMNS.include?(column)
      raise ArgumentError, "untrusted column #{column.inspect} — add it to NORMALIZABLE_COLUMNS if it is safe"
    end

    remapped = AGENT_TYPES.filter_map do |agent_type|
      provider_key = ProviderSupport.provider_key_for_agent_type(agent_type)
      next if provider_key == agent_type

      "WHEN #{connection.quote(agent_type)} THEN #{connection.quote(provider_key)}"
    end

    return column if remapped.empty?

    "CASE #{column} #{remapped.join(" ")} ELSE #{column} END"
  end

  def self.normalized_agent_type_sql
    normalize_provider_sql("agent_type")
  end

  # SQL expression for the effective provider: the provider that actually
  # produced the output. Mirrors the Ruby #effective_provider method so that
  # both SQL aggregations and Ruby code share the same logic.
  def self.effective_provider_sql
    "COALESCE(#{normalize_provider_sql("NULLIF(final_provider, '')")}, #{normalized_agent_type_sql})"
  end

  ransacker :tokens_total, type: :integer do
    Arel.sql("COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)")
  end

  ransacker :effective_provider do
    Arel.sql(effective_provider_sql)
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[status agent_type branch_name trigger_type goal duration_seconds tokens_input tokens_output tokens_total cost_cents created_at started_at effective_provider]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[project]
  end

  def self.distinct_effective_providers
    pluck(Arel.sql("DISTINCT #{effective_provider_sql}"))
      .compact
      .sort
  end

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
    scope = active.joins(:project).where(projects: { created_by_id: user.id })

    if orphaned_project_owner?(user)
      scope = scope.or(
        active.joins(:project).where(
          projects: { created_by_id: nil, account_id: user.account_id }
        )
      )
    end

    scope.count
  end

  # Returns the count of active runs for a given project.
  def self.active_count_for_project(project)
    active.where(project_id: project.id).count
  end

  # Returns the count of unfinished (queued/pending/running/paused) auto-pick
  # runs attributable to the given user. Used by queue seeding to cap queued
  # auto-pick work at the user's max_concurrent_runs instead of seeding every
  # eligible issue. Mirrors active_count_for_user's owner-resolution chain.
  #
  # Filters on the explicit `auto_pick: true` column set by
  # Issues::AutoPick#create_agent_run. The column is set on every new auto-pick
  # run, so the count is accurate for seeding decisions.
  def self.unfinished_auto_pick_count_for_user(user)
    base = where(status: UNFINISHED_STATUSES, auto_pick: true)
    scope = base.joins(:project).where(projects: { created_by_id: user.id })

    if orphaned_project_owner?(user)
      scope = scope.or(
        base.joins(:project).where(
          projects: { created_by_id: nil, account_id: user.account_id }
        )
      )
    end

    scope.count
  end

  def self.stale_running_timeout
    AGENT_TIMEOUT_DEFAULT.seconds + STALE_RUNNING_GRACE_PERIOD
  end

  def self.stale_pending_timeout
    STALE_PENDING_TIMEOUT
  end

  def self.stale_paused_timeout
    STALE_PAUSED_TIMEOUT
  end

  def self.stale_running_cutoff(now: Time.current)
    now - stale_running_timeout
  end

  def self.stale_pending_cutoff(now: Time.current)
    now - stale_pending_timeout
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

  # Priority ordering for the run queue (6 tiers):
  #   0 = P1 user-defined label (highest)
  #   1 = manual runs
  #   2 = P2 user-defined label
  #   3 = automatic runs fixing a PR (auto-continue)
  #   4 = P3 user-defined label
  #   5 = automatic runs from auto-pick (lowest)
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
    label_p1: { label: "P1", indicator: 1 },
    manual: { label: "Manual", indicator: 2 },
    label_p2: { label: "P2", indicator: 3 },
    auto_continue: { label: "Auto-continue", indicator: 4 },
    label_p3: { label: "P3", indicator: 5 },
    auto_pick: { label: "Auto-pick", indicator: 6 }
  }.freeze
  UNKNOWN_PRIORITY = { label: "Unknown", indicator: nil }.freeze

  def queue_priority_tier
    label_tier = label_priority_tier
    return :label_p1 if label_tier == "P1"

    if manual?
      :manual
    elsif label_tier == "P2"
      :label_p2
    elsif automatic? && existing_pr?
      :auto_continue
    elsif label_tier == "P3"
      :label_p3
    else
      :auto_pick
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
  # name matching is case-sensitive on both the Ruby and SQL sides; an
  # issue tagged "p1" will not match a configured tier of "P1".
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
      label_sources.any? { |labels| labels.include?(label_name) }
    end
  end
  private :compute_label_priority_tier

  attr_writer :source_pull_request_record

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
  # Project#effective_priority_labels. Element matching is case-sensitive.
  #
  # NOTE: This SQL contains no interpolated values — the tier names are
  # hardcoded literals — so it is not a SQL injection vector.
  QUEUE_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN issue_labels.labels @> jsonb_build_array(COALESCE(NULLIF(p.priority_labels->>'P1', ''), 'P1')) THEN 0
      WHEN trigger_type = 'manual' THEN 1
      WHEN issue_labels.labels @> jsonb_build_array(COALESCE(NULLIF(p.priority_labels->>'P2', ''), 'P2')) THEN 2
      WHEN trigger_type = 'automatic' AND source_pull_request_number IS NOT NULL THEN 3
      WHEN issue_labels.labels @> jsonb_build_array(COALESCE(NULLIF(p.priority_labels->>'P3', ''), 'P3')) THEN 4
      ELSE 5
    END
  SQL
  QUEUE_PRIORITY_SQL = Arel.sql(QUEUE_PRIORITY_CASE_SQL).freeze
  GOAL_PRIORITY_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN goal IN ('create_issue', 'enhance_issue', 'analyze_issue') THEN 0
      ELSE 1
    END
  SQL
  GOAL_PRIORITY_SQL = Arel.sql(GOAL_PRIORITY_CASE_SQL).freeze
  PROJECT_ACTIVE_COUNT_CASE_SQL = <<~SQL.squish.freeze
    CASE
      WHEN COALESCE(user_settings.fair_queue_across_projects, TRUE)
        THEN COALESCE(project_active_counts.project_active_count, 0)
      ELSE 0
    END
  SQL
  PROJECT_ACTIVE_COUNT_SQL = Arel.sql("#{PROJECT_ACTIVE_COUNT_CASE_SQL} ASC").freeze
  USER_ACTIVE_COUNT_SQL = Arel.sql("COALESCE(user_active_counts.user_active_count, 0) ASC").freeze
  QUEUE_ORDER = [ QUEUE_PRIORITY_SQL, USER_ACTIVE_COUNT_SQL, GOAL_PRIORITY_SQL, { created_at: :asc, id: :asc } ].freeze
  WITHIN_OWNER_QUEUE_ORDER = [ PROJECT_ACTIVE_COUNT_SQL, GOAL_PRIORITY_SQL, { created_at: :asc, id: :asc } ].freeze

  # Scope that adds the CTE and joins required by QUEUE_ORDER.
  # All queue-ordering methods use this instead of bare `queued`.
  scope :queued_with_priority, -> {
    queued
      .with(
        project_active_counts: project_active_counts_cte,
        user_active_counts: user_active_counts_cte
      )
      .joins(QUEUE_LATERAL_JOIN)
      .joins("LEFT JOIN project_active_counts ON project_active_counts.project_id = agent_runs.project_id")
      .joins("LEFT JOIN user_active_counts ON user_active_counts.user_id = project_owner.user_id")
      .joins("LEFT JOIN user_settings ON user_settings.user_id = project_owner.user_id")
      .select(
        "agent_runs.*",
        "#{QUEUE_PRIORITY_CASE_SQL} AS queue_priority",
        "#{GOAL_PRIORITY_CASE_SQL} AS goal_priority",
        "#{PROJECT_ACTIVE_COUNT_CASE_SQL} AS project_active_count",
        "COALESCE(user_active_counts.user_active_count, 0) AS user_active_count",
        "project_owner.user_id AS project_owner_user_id",
        "COALESCE(user_settings.fair_queue_across_projects, TRUE) AS fair_queue_across_projects"
      )
  }

  def self.project_active_counts_cte
    active
      .select("project_id, COUNT(*) AS project_active_count")
      .group(:project_id)
  end

  # CTE that counts pending + running runs per effective user (owner).
  # Orphaned projects (created_by_id IS NULL) are attributed to the
  # account's fallback owner using the same COALESCE chain as
  # QUEUE_LATERAL_JOIN. Paused runs are excluded (only ACTIVE_STATUSES
  # are counted) so a paused run does not inflate a user's stride.
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
      WHERE agent_runs.status IN ('pending', 'running')
      GROUP BY owner.user_id
    SQL
  end

  def self.next_queued_run
    next_queued_run_from(queued_with_priority)
  end

  # Returns the next queued run without claiming it.
  # Used to check per-user capacity before acquiring the lock.
  #
  # Runs whose project belongs to an account with a paused scheduler are
  # excluded so a "pause all" toggle can hold new starts while still
  # accepting new queue entries from the project trigger button.
  def self.peek_next_queued_run(exclude_ids: [])
    scope = queued_with_priority
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?
    scope = scope.joins(project: :account).where(accounts: { scheduler_paused_at: nil })
    scope = scope.where(projects: { scheduler_paused_at: nil })
    scope = scope.where(
      "agent_runs.trigger_type = 'manual' OR projects.quality_paused_at IS NULL"
    )
    next_queued_run_from(scope)
  end

  def self.next_queued_run_from(scope)
    first = scope.reorder(QUEUE_ORDER).first
    return unless first
    return first unless first.project_owner_user_id
    return first unless truthy_queue_attribute?(first.fair_queue_across_projects)

    boundary = first_different_owner_run(scope, first)
    same_owner_scope = same_owner_priority_scope(scope, first)
    if boundary
      same_owner_scope = same_owner_scope.where(
        "(#{GOAL_PRIORITY_CASE_SQL}, agent_runs.created_at, agent_runs.id) < (?, ?, ?)",
        boundary.goal_priority.to_i, boundary.created_at, boundary.id
      )
    end

    same_owner_scope.reorder(WITHIN_OWNER_QUEUE_ORDER).first || first
  end
  private_class_method :next_queued_run_from

  def self.first_different_owner_run(scope, first)
    scope
      .where("#{QUEUE_PRIORITY_CASE_SQL} = ?", first.queue_priority.to_i)
      .where("project_owner.user_id IS DISTINCT FROM ?", first.project_owner_user_id)
      .reorder(QUEUE_ORDER)
      .first
  end
  private_class_method :first_different_owner_run

  def self.same_owner_priority_scope(scope, first)
    scope
      .where("project_owner.user_id = ?", first.project_owner_user_id)
      .where("#{QUEUE_PRIORITY_CASE_SQL} = ?", first.queue_priority.to_i)
  end
  private_class_method :same_owner_priority_scope

  def self.truthy_queue_attribute?(value)
    value == true || %w[1 t true].include?(value.to_s)
  end
  private_class_method :truthy_queue_attribute?

  def provider_belongs_to_project_owner
    owner = project&.effective_owner
    return unless owner
    return if provider.user_id == owner.id

    errors.add(:provider, "must belong to the same user as the project owner")
  end

  # Atomically claims a queued run by transitioning it to pending inside a
  # transaction with FOR UPDATE SKIP LOCKED. Returns nil if the run is no
  # longer queued or another process already claimed it.
  #
  # @param target_id [Integer] the specific run to claim (identified by a
  #   prior peek_next_queued_run call)
  #
  # Note: if the transaction commits but the subsequent workflow start fails,
  # the run stays "pending" without an associated workflow. ProcessRunQueueJob
  # handles this by marking such runs as failed in its rescue block.
  def self.claim_next_queued_run(target_id:)
    transaction do
      run = queued.where(id: target_id).lock("FOR UPDATE SKIP LOCKED").first
      return nil unless run

      run.update!(status: "pending")
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
  # issue (provider exhaustion, timeout, auth expiry, rate limiting) rather
  # than a code-level failure. Used by the PR scanner's operational failure
  # breaker to detect when a PR is stalled due to infrastructure problems
  # that the agent cannot fix by retrying.
  #
  # A "failed" run is only operational when the error message indicates
  # provider exhaustion or rate limiting — other "failed" runs are assumed
  # to be code-level failures where a retry might help.
  def operational_failure?
    return false unless FAILURE_STATUSES.include?(status)
    return true if status.in?(%w[timeout auth_expired rate_limited])

    OPERATIONAL_FAILURE_KEYWORDS.any? do |keyword|
      error_message.to_s.downcase.include?(keyword.downcase)
    end
  end

  def total_tokens
    tokens_input.to_i + tokens_output.to_i
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
    return nil unless status.in?(%w[queued pending running])

    return "queue" if status.in?(%w[queued pending])

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
      setup_seconds: grouped.fetch("setup", 0),
      prompt_seconds: grouped.fetch("prompt", 0),
      agent_seconds: grouped.fetch("agent", 0),
      post_seconds: grouped.fetch("post", 0),
      cleanup_seconds: grouped.fetch("cleanup", 0),
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

  def pause!(violation_type:, context: nil)
    with_lock do
      reload
      return false unless running?

      update!(
        status: "paused",
        paused_at: Time.current,
        guardrail_violation_type: violation_type,
        guardrail_context: context
      )
      true
    end
  end

  def paused?
    status == "paused"
  end

  def resume!
    with_lock do
      reload
      return false unless paused?

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

  def timeout!(error: nil)
    with_lock do
      reload
      if finished?
        false
      else
        update!(
          status: "timeout",
          completed_at: Time.current,
          error_message: error,
          duration_seconds: duration
        )
      end
    end
  end

  # True when this run was force-timed-out externally (by `dev:cleanup` or
  # `StaleRunDetectorJob`), not by the provider itself. The in-flight Temporal
  # activity uses this to suppress provider circuit-breaker bookkeeping for
  # failures that the external cleanup induced, not the provider.
  def cancelled_by_cleanup?
    return false unless status == "timeout"

    error_message.to_s.start_with?(STALE_CLEANUP_ERROR_PREFIX, STALE_DETECTOR_ERROR_PREFIX)
  end

  def retried?
    status == "retried"
  end

  def retry!
    update!(status: "retried")
  end

  def auth_expired?
    status == "auth_expired"
  end

  def auth_expire!(error: nil, provider: nil)
    update!(
      status: "auth_expired",
      completed_at: Time.current,
      error_message: error,
      auth_provider: provider,
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
    return nil unless issue.trusted?

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

  # Returns the prompt for this run: custom_prompt if provided,
  # otherwise delegates to goal-specific prompt builders.
  #
  # @return [String, nil] The prompt to send to the agent
  def effective_prompt
    custom_prompt.presence || prompt_for_goal
  end

  # Returns the base prompt for the review goal.
  # The review_goal_requires_pull_request validation ensures
  # source_pull_request_number is always present for review goals.
  #
  # @return [String] The review prompt
  def prompt_for_review
    "Review pull request ##{source_pull_request_number} in #{project.full_name}."
  end

  # Returns the provider that actually produced the output for this run.
  # Prefers final_provider (the provider that ultimately completed successfully)
  # when present, otherwise falls back to agent_type (the originally requested provider).
  # Note: whether a fallback occurred should be determined via provider tracking
  # fields (e.g., providers_attempted / provider_switches), not by final_provider alone.
  #
  # @return [String] The effective provider name
  def effective_provider
    ProviderSupport.provider_key_for_agent_type(final_provider.presence || agent_type)
  end

  def final_provider_record
    owner = project&.effective_owner
    return unless owner

    return unless final_provider.present?

    provider_id = Provider.id_from_routing_key(final_provider)
    owner.providers.find_by(id: provider_id) if provider_id
  end

  # Returns the Provider record that reflects which provider actually ran the
  # agent. Prefers the final provider (post-fallback) when resolvable, falling
  # back to the initially-assigned provider. Handles both routing-key and
  # provider-key forms of final_provider via Provider.for_identifier. Returns
  # nil if neither can be resolved.
  def effective_provider_record
    Provider.for_identifier(project&.effective_owner, final_provider) || provider
  end

  def attempted_providers_by_routing_key
    owner = project&.effective_owner
    return {} unless owner

    routing_ids = providers_attempted.filter_map do |attempt|
      Provider.id_from_routing_key(attempt["provider"])
    end
    return {} if routing_ids.empty?

    owner.providers.where(id: routing_ids).index_by(&:routing_key)
  end

  # Records a provider attempt in the providers_attempted array.
  #
  # @param provider [String] The provider name
  # @param success [Boolean] Whether the attempt succeeded
  # @param error_type [String, nil] Type of error if failed (e.g., "rate_limited", "error")
  def record_provider_attempt(provider, success:, error_type: nil, error_message: nil, duration_seconds: nil)
    attempt = {
      "provider" => provider,
      "success" => success,
      "attempted_at" => Time.current.iso8601
    }
    attempt["error_type"] = error_type if error_type.present?
    sanitized_error_message = sanitize_provider_attempt_error_message(error_message)
    attempt["error_message"] = sanitized_error_message if sanitized_error_message.present?
    attempt["duration_seconds"] = duration_seconds if duration_seconds.present?

    self.providers_attempted = (providers_attempted || []) + [ attempt ]
    save!
  end

  # Logs a provider switch and increments the switch counter.
  #
  # @param from [String] The provider being switched from
  # @param to [String] The provider being switched to
  # @param reason [String] Why the switch occurred
  def log_provider_switch!(from, to, reason)
    log!("system", "Provider fallback: #{from} -> #{to} (#{reason})")
    increment!(:provider_switches)
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
      update!(container_id: pooled_result[:container_id])
      return pooled_result
    end

    @container_service = Containers::Provision.new(
      agent_run: self,
      worktree_path: worktree_path.presence,
      **options
    )
    result = @container_service.provision
    if result.success?
      update!(container_id: result[:container_id])
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
  def with_container(**options, &block)
    Containers::Provision.with_container(
      agent_run: self,
      worktree_path: worktree_path.presence,
      **options
    ) do |service|
      @container_service = service
      block.call(self)
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

    parsed = AgentHarness::Providers::Anthropic.parse_cli_json_envelope(raw_stdout)
    if parsed
      if parsed[:error].present?
        return "Agent encountered an error: #{parsed[:error]}"
      else
        return parsed[:output].presence || raw_stdout
      end
    end

    jsonl_text = extract_text_from_jsonl_transcript(raw_stdout)
    jsonl_text || raw_stdout
  end

  def extract_text_from_jsonl_transcript(raw_stdout)
    parsed = AgentHarness::Providers::Codex.parse_cli_jsonl_transcript(raw_stdout, max_events: 500)
    parsed[:text].presence if parsed
  end

  def normalize_log_content(content)
    text = content.to_s
    return text.delete("\x00") if text.encoding == Encoding::UTF_8 && text.valid_encoding?

    text.dup.force_encoding(Encoding::UTF_8).scrub.delete("\x00")
  end

  def sanitize_provider_attempt_error_message(message)
    return nil if message.blank?

    normalized = normalize_log_content(message)
    redacted = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
    redacted.truncate(MAX_PROVIDER_ATTEMPT_ERROR_MESSAGE_LENGTH)
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
    Docker::Volume.get(volume_name).remove
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

  private :explicit_user_max_tokens_per_run

  def just_timed_out_issue_goal?
    previous_changes.key?("status") && status == "timeout" && create_issue_goal?
  end

  def enqueue_issue_goal_timeout_retry
    RetryTimedOutIssueGoalJob.perform_later(id)
  end

  def enqueue_container_metrics_collection
    ContainerMetricsCollectionJob.perform_later(id) if container_id.present?
  end

  def broadcast_project_updates
    if previous_changes.key?("status") || previous_changes.key?("issue_id") || previous_changes.key?("agent_type")
      project.broadcast_agent_runs_update
      project.broadcast_agent_runs_list_update
      project.broadcast_stats_update
      # Only broadcast issues updates when they can affect auto-pick eligibility
      # or when the associated issue/agent type changes. This avoids redundant
      # re-renders during intermediate status transitions (e.g., queued→pending→running).
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

      # Only broadcast dashboard stats on terminal status transitions to avoid
      # a burst of expensive aggregate queries during intermediate transitions
      # (queued→pending→running→completed). The Turbo Stream partials for
      # project-level stats already cover the real-time detail view.
      DashboardBroadcastJob.perform_later(project.account_id) if finished?
    end

    if previous_changes.key?("status")
      LiveDashboardBroadcastJob.perform_later(project.account_id, id)
    end

    project.broadcast_agent_run_detail_update(self)
  end
end
