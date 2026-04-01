# frozen_string_literal: true

class AgentRun < ApplicationRecord
  STATUSES = %w[queued pending running completed failed cancelled timeout retried auth_expired rate_limited].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot aider gemini opencode kilocode api].freeze
  GOALS = %w[create_pr create_issue review].freeze
  TRIGGER_TYPES = %w[manual automatic].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  FINISHED_STATUSES = %w[completed failed cancelled timeout retried auth_expired rate_limited].freeze
  FAILURE_STATUSES = %w[failed timeout auth_expired rate_limited].freeze
  UNFINISHED_STATUSES = %w[queued pending running].freeze
  AUTO_PICK_BLOCKING_STATUSES = UNFINISHED_STATUSES

  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :prompt_version, optional: true
  belongs_to :provider, optional: true

  has_many :agent_run_logs, dependent: :destroy
  has_many :agent_run_phases, -> { order(:started_at, :id) }, dependent: :destroy
  has_many :token_usages, dependent: :destroy
  has_many :ab_test_assignments, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all
  has_many :quality_metrics, dependent: :destroy
  has_one :worktree, dependent: :nullify
  has_one :model_selection, dependent: :destroy
  has_one :decision_record, dependent: :nullify

  attr_readonly :mcp_server_snapshot

  before_create :generate_proxy_token
  before_create :snapshot_mcp_servers

  after_commit :broadcast_project_updates, on: [ :create, :update ]
  after_commit :update_project_last_agent_run_at, on: :create
  after_commit :enqueue_quality_metrics_collection, on: :update, if: :just_finished?
  after_commit :enqueue_container_metrics_collection, on: :update, if: :just_started_running?

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :goal, presence: true, inclusion: { in: GOALS }
  validate :review_goal_requires_pull_request
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
  validates :container_id, length: { maximum: 128 }
  validates :iterations, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_input, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_output, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source_pull_request_number, numericality: { greater_than: 0 }, allow_nil: true
  validates :auth_provider, length: { maximum: 50 }
  validates :diagnosis_status, inclusion: { in: %w[in_progress processing completed failed] }, allow_nil: true
  validates :diagnosis_issue_url, length: { maximum: 500 }
  validates :final_provider, length: { maximum: 50 }
  validates :provider_switches, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :stale_requeue_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
  validate :provider_belongs_to_project_owner, if: -> { provider.present? }
  validate :has_prompt_source, on: :create

  scope :by_status, ->(status) { where(status: status) }
  scope :queued, -> { where(status: "queued") }
  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :timeout, -> { where(status: "timeout") }
  scope :retried, -> { where(status: "retried") }
  scope :auth_expired, -> { where(status: "auth_expired") }
  scope :rate_limited, -> { where(status: "rate_limited") }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :finished, -> { where(status: FINISHED_STATUSES) }
  scope :recent, -> { order(created_at: :desc) }
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

  def self.ransackable_attributes(auth_object = nil)
    %w[status agent_type branch_name trigger_type goal duration_seconds tokens_input tokens_output tokens_total cost_cents created_at started_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[project]
  end

  def duration
    return nil unless started_at

    end_time = completed_at || Time.current
    [ (end_time - started_at).to_i, 0 ].max
  end

  # Checks whether the given user has capacity for another agent run.
  #
  # Capacity is determined solely by the user's max_concurrent_runs setting.
  # Returns false (fail closed) when no user is provided, so orphaned
  # projects or unresolvable owners cannot bypass concurrency limits.
  def self.has_run_capacity?(user: nil)
    return false unless user

    active_count_for_user(user) < user.settings.max_concurrent_runs
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

  # Returns true if this user is the fallback owner for orphaned
  # projects in their account. Delegates to Account#fallback_owner_id
  # for shared, deterministic resolution matching Project#effective_owner.
  def self.orphaned_project_owner?(user)
    user.account.fallback_owner_id == user.id
  end

  # Priority ordering for the run queue:
  #   0 = manual runs (highest)
  #   1 = automatic runs fixing a PR (auto-continue)
  #   2 = automatic runs from auto-pick (lowest)
  # Within each tier, create_issue runs are prioritized over create_pr
  # runs because issue creation is lighter-weight and often unblocks
  # downstream PR work.
  # Within each goal type, runs are processed FIFO by created_at, with
  # id as a stable tiebreaker for runs created in the same timestamp.
  #
  # NOTE: The SQL sort tiers above (0/1/2) are internal ordering values.
  # The `indicator` values below (1/2/3) are user-facing display labels
  # shown in the priority badge (e.g. "1 - Manual").
  QUEUE_PRIORITIES = {
    manual: { label: "Manual", indicator: 1 },
    auto_continue: { label: "Auto-continue", indicator: 2 },
    auto_pick: { label: "Auto-pick", indicator: 3 }
  }.freeze
  UNKNOWN_PRIORITY = { label: "Unknown", indicator: nil }.freeze

  def queue_priority_tier
    if manual?
      :manual
    elsif automatic? && existing_pr?
      :auto_continue
    else
      :auto_pick
    end
  end

  def queue_priority_label
    priority = QUEUE_PRIORITIES.fetch(queue_priority_tier) { UNKNOWN_PRIORITY }
    indicator = priority[:indicator]
    indicator ? "#{indicator} - #{priority[:label]}" : priority[:label]
  end

  QUEUE_PRIORITY_SQL = Arel.sql(<<~SQL.squish).freeze
    CASE
      WHEN trigger_type = 'manual' THEN 0
      WHEN trigger_type = 'automatic' AND source_pull_request_number IS NOT NULL THEN 1
      ELSE 2
    END
  SQL
  GOAL_PRIORITY_SQL = Arel.sql(<<~SQL.squish).freeze
    CASE
      WHEN goal = 'create_issue' THEN 0
      ELSE 1
    END
  SQL
  QUEUE_ORDER = [ QUEUE_PRIORITY_SQL, GOAL_PRIORITY_SQL, { created_at: :asc, id: :asc } ].freeze

  def self.next_queued_run
    queued.order(QUEUE_ORDER).first
  end

  # Returns the next queued run without claiming it.
  # Used to check per-user capacity before acquiring the lock.
  def self.peek_next_queued_run(exclude_ids: [])
    scope = queued.order(QUEUE_ORDER)
    scope = scope.where.not(id: exclude_ids) if exclude_ids.any?
    scope.first
  end

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

  def running?
    status == "running"
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  def successful?
    status == "completed"
  end

  def total_tokens
    tokens_input + tokens_output
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

  def phase_timeline
    agent_run_phases
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

  def result_url
    pull_request_url || created_issue_url
  end

  def fail!(error: nil)
    update!(
      status: "failed",
      completed_at: Time.current,
      error_message: error,
      duration_seconds: duration
    )
  end

  def cancel!
    update!(
      status: "cancelled",
      completed_at: Time.current,
      duration_seconds: duration
    )
  end

  def timeout!(error: nil)
    update!(
      status: "timeout",
      completed_at: Time.current,
      error_message: error,
      duration_seconds: duration
    )
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
      content: content.to_s.delete("\x00"),
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

    Prompts::BuildForIssue.call(issue: issue, project: project, github_client: project.github_token&.client)
  end

  # Returns the agent's stdout output joined as a single string.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The agent summary text (may be empty)
  def agent_summary(limit: 500)
    logs_text(log_type: "stdout", limit: limit)
  end

  # Returns the agent's output, preferring stdout but falling back to stderr.
  # Useful for issue-goal runs where agents may write drafted content to stderr.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The best available agent output (may be empty)
  def agent_summary_with_stderr_fallback(limit: 500)
    summary = logs_text(log_type: "stdout", limit: limit)
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

  def attempted_providers_by_routing_key
    owner = project&.effective_owner
    return {} unless owner

    return {} unless provider_switches.positive?

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
  def record_provider_attempt(provider, success:, error_type: nil)
    attempt = {
      "provider" => provider,
      "success" => success,
      "attempted_at" => Time.current.iso8601
    }
    attempt["error_type"] = error_type if error_type.present?

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
    @container_service = Containers::Provision.new(
      agent_run: self,
      worktree_path: worktree_path.presence,
      **options
    )
    result = @container_service.provision
    update!(container_id: result[:container_id]) if result.success?
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
  def execute_in_container(command, timeout: nil, stream: true, env: {})
    ensure_container_service!
    @container_service.execute(command, timeout: timeout, stream: stream, env: env)
  end

  # Cleans up the provisioned container.
  #
  # @param force [Boolean] Force kill if container doesn't stop gracefully
  # @return [void]
  def cleanup_container(force: false)
    return if container_id.blank? && @container_service.nil?

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

  def prompt_for_goal
    if review_goal?
      prompt_for_review
    else
      prompt_for_issue
    end
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

  def just_finished?
    previous_changes.key?("status") && finished?
  end

  def enqueue_quality_metrics_collection
    QualityMetricsCollectionJob.perform_later(id)
    HumanFeedbackCollectionJob.set(wait: 5.minutes).perform_later(id) if successful?
  end

  def just_started_running?
    previous_changes.key?("status") && status == "running"
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
