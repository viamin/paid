# frozen_string_literal: true

class AgentRun < ApplicationRecord
  STATUSES = %w[pending running completed failed cancelled timeout].freeze
  AGENT_TYPES = %w[claude_code cursor codex copilot aider gemini opencode kilocode api].freeze

  belongs_to :project
  belongs_to :issue, optional: true

  has_many :agent_run_logs, dependent: :destroy
  has_one :worktree, dependent: :nullify

  before_create :generate_proxy_token

  validates :agent_type, presence: true, inclusion: { in: AGENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :worktree_path, length: { maximum: 500 }
  validates :branch_name, length: { maximum: 255 }
  validates :base_commit_sha, length: { maximum: 40 }
  validates :result_commit_sha, length: { maximum: 40 }
  validates :pull_request_url, length: { maximum: 500 }
  validates :temporal_workflow_id, length: { maximum: 255 }
  validates :temporal_run_id, length: { maximum: 255 }
  validates :iterations, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_input, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :tokens_output, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :duration_seconds, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :issue_belongs_to_same_project, if: -> { issue.present? }

  scope :by_status, ->(status) { where(status: status) }
  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :cancelled, -> { where(status: "cancelled") }
  scope :timeout, -> { where(status: "timeout") }
  scope :active, -> { where(status: %w[pending running]) }
  scope :finished, -> { where(status: %w[completed failed cancelled timeout]) }
  scope :recent, -> { order(created_at: :desc) }

  def duration
    return nil unless started_at

    end_time = completed_at || Time.current
    (end_time - started_at).to_i
  end

  def running?
    status == "running"
  end

  def finished?
    %w[completed failed cancelled timeout].include?(status)
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

  def complete!(result_commit: nil, pr_url: nil, pr_number: nil)
    update!(
      status: "completed",
      completed_at: Time.current,
      result_commit_sha: result_commit,
      pull_request_url: pr_url,
      pull_request_number: pr_number,
      duration_seconds: duration
    )
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

  def timeout!
    update!(
      status: "timeout",
      completed_at: Time.current,
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
    args[:timeout] = timeout if timeout

    AgentRuns::Execute.call(**args)
  end

  # Builds a prompt for this run's issue using the PromptBuilder.
  #
  # @return [String, nil] The built prompt, or nil if no issue is attached
  def prompt_for_issue
    return nil unless issue

    Prompts::BuildForIssue.call(issue: issue, project: project)
  end

  # Container management integration methods.
  # These delegate to Containers::Provision for actual implementation.

  # Provisions a Docker container for this agent run.
  #
  # @param options [Hash] Override default container options
  # @return [Containers::Provision::Result] Result with container_id on success
  # @raise [Containers::Provision::ProvisionError] When container creation fails
  def provision_container(**options)
    raise ArgumentError, "worktree_path is required" if worktree_path.blank?

    @container_service = Containers::Provision.new(
      agent_run: self,
      worktree_path: worktree_path,
      **options
    )
    @container_service.provision
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
    raise Containers::Provision::ProvisionError, "Container not provisioned" unless @container_service

    @container_service.execute(command, timeout: timeout, stream: stream)
  end

  # Cleans up the provisioned container.
  #
  # @param force [Boolean] Force kill if container doesn't stop gracefully
  # @return [void]
  def cleanup_container(force: false)
    return unless @container_service

    @container_service.cleanup(force: force)
    @container_service = nil
  end

  # Executes a block with a provisioned container, ensuring cleanup.
  #
  # @param options [Hash] Override default container options
  # @yield [self] The agent run with provisioned container
  # @return [Object] The return value of the block
  def with_container(**options, &block)
    raise ArgumentError, "worktree_path is required" if worktree_path.blank?

    Containers::Provision.with_container(
      agent_run: self,
      worktree_path: worktree_path,
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
  def ensure_proxy_token!
    return proxy_token if proxy_token.present?

    token = SecureRandom.hex(32)
    update_column(:proxy_token, token)
    self.proxy_token = token
  end

  private

  def issue_belongs_to_same_project
    return if issue.project_id == project_id

    errors.add(:issue, "must belong to the same project")
  end

  def generate_proxy_token
    self.proxy_token ||= SecureRandom.hex(32)
  end
end
