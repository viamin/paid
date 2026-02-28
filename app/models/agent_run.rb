# frozen_string_literal: true

class AgentRun < ApplicationRecord
  STATUSES = %w[queued pending running completed failed cancelled timeout retried].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot aider gemini opencode kilocode api].freeze
  GOALS = %w[create_pr create_issue].freeze

  belongs_to :project
  belongs_to :issue, optional: true
  belongs_to :prompt_version, optional: true

  has_many :agent_run_logs, dependent: :destroy
  has_one :worktree, dependent: :nullify

  before_create :generate_proxy_token

  after_commit :broadcast_project_updates, on: [ :create, :update ]

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :goal, presence: true, inclusion: { in: GOALS }
  validates :created_issue_url, length: { maximum: 500 }
  validates :worktree_path, length: { maximum: 500 }
  validates :branch_name, length: { maximum: 255 }
  validates :base_commit_sha, length: { maximum: 40 }
  validates :result_commit_sha, length: { maximum: 40 }
  validates :pull_request_url, length: { maximum: 500 }
  validates :temporal_workflow_id, length: { maximum: 255 }
  validates :temporal_run_id, length: { maximum: 255 }
  validates :container_id, length: { maximum: 128 }
  validates :iterations, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_input, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_output, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :source_pull_request_number, numericality: { greater_than: 0 }, allow_nil: true
  validate :issue_belongs_to_same_project, if: -> { issue.present? }
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
  scope :active, -> { where(status: %w[pending running]) }
  scope :finished, -> { where(status: %w[completed failed cancelled timeout retried]) }
  scope :recent, -> { order(created_at: :desc) }

  ransacker :tokens_total, type: :integer do
    Arel.sql("COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)")
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[status agent_type branch_name duration_seconds tokens_input tokens_output tokens_total cost_cents created_at started_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[project]
  end

  def duration
    return nil unless started_at

    end_time = completed_at || Time.current
    (end_time - started_at).to_i
  end

  def self.has_run_capacity?
    active.count < Rails.application.config.x.max_concurrent_runs
  end

  def self.next_queued_run
    queued.order(created_at: :asc).first
  end

  # Atomically claims the oldest queued run by transitioning it to pending
  # inside a transaction with FOR UPDATE SKIP LOCKED. Returns nil if no
  # queued run is available or another process already claimed it.
  #
  # Note: if the transaction commits but the subsequent workflow start fails,
  # the run stays "pending" without an associated workflow. ProcessRunQueueJob
  # handles this by marking such runs as failed in its rescue block.
  def self.claim_next_queued_run
    transaction do
      run = queued.order(created_at: :asc).lock("FOR UPDATE SKIP LOCKED").first
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

  def queued?
    status == "queued"
  end

  def active?
    %w[pending running].include?(status)
  end

  def running?
    status == "running"
  end

  def finished?
    %w[completed failed cancelled timeout retried].include?(status)
  end

  def successful?
    status == "completed"
  end

  def total_tokens
    tokens_input + tokens_output
  end

  def start!
    update!(status: "running", started_at: Time.current)
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

  # Creates a log entry for this agent run.
  #
  # @param type [String] Log type: stdout, stderr, system, or metric
  # @param content [String] The log content
  # @param metadata [Hash] Optional metadata to store as JSON
  # @return [AgentRunLog] The created log entry
  def log!(type, content, metadata: nil)
    agent_run_logs.create!(
      log_type: type,
      content: content,
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

    Prompts::BuildForIssue.call(issue: issue, project: project)
  end

  # Returns the agent's stdout output joined as a single string.
  #
  # @param limit [Integer] Max number of log entries to fetch (default 500)
  # @return [String] The agent summary text (may be empty)
  def agent_summary(limit: 500)
    agent_run_logs
      .where(log_type: "stdout")
      .order(:created_at)
      .limit(limit)
      .pluck(:content)
      .join("\n")
      .strip
  end

  # Returns the prompt for this run: custom_prompt if provided,
  # otherwise delegates to prompt_for_issue.
  #
  # @return [String, nil] The prompt to send to the agent
  def effective_prompt
    custom_prompt.presence || prompt_for_issue
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
  def execute_in_container(command, timeout: nil, stream: true)
    ensure_container_service!
    @container_service.execute(command, timeout: timeout, stream: stream)
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

  def broadcast_project_updates
    if previous_changes.key?("status") || previous_changes.key?("issue_id") || previous_changes.key?("agent_type")
      project.broadcast_agent_runs_update
      project.broadcast_agent_runs_list_update
      project.broadcast_stats_update
    end

    project.broadcast_agent_run_detail_update(self)
  end
end
