# frozen_string_literal: true

class ExecutionResource < ApplicationRecord # @spec CONTAINER-RUNTIME-032
  RESOURCE_TYPES = %w[environment workspace].freeze
  STATES = %w[active cleanup_pending cleaned].freeze
  CLEANUP_BASE_DELAY = 5.minutes
  CLEANUP_MAX_DELAY = 1.day

  belongs_to :account, optional: true
  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true

  scope :active, -> { where(state: "active") }
  scope :cleanup_pending, -> { where(state: "cleanup_pending") }
  scope :cleaned, -> { where(state: "cleaned") }
  scope :active_or_pending, -> { where(state: %w[active cleanup_pending]) }
  scope :due_for_cleanup, -> {
    cleanup_pending.where("next_cleanup_at IS NULL OR next_cleanup_at <= ?", Time.current)
  }
  scope :environments, -> { where(resource_type: "environment") }

  validates :resource_type, presence: true, inclusion: { in: RESOURCE_TYPES }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :runner_type, presence: true
  validates :identifier, presence: true
  validates :host, presence: true
  validates :cleanup_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  before_validation :populate_owner_fields_from_agent_run
  before_validation :normalize_host

  def self.track_environment!(agent_run:, handle: nil, identifier: nil, host: nil, runner_type: nil)
    agent_run_id = safe_agent_run_id(agent_run)
    return unless agent_run_id.present?

    handle ||= ExecutionRunners::RunnerHandle.from_record(agent_run)
    identifier ||= handle&.identifier || agent_run.container_id
    return unless identifier.present?

    resource = environments.find_or_initialize_by(agent_run: agent_run)
    resource.assign_attributes(
      account: agent_run.project.account,
      project: agent_run.project,
      runner_type: (runner_type || handle&.runner_type || :local_docker).to_s,
      identifier: identifier,
      host: normalize_provider_host(host || handle&.host || agent_run.workspace_volume_host),
      runner_handle: (handle || build_legacy_handle(agent_run:, identifier:, host:)).to_storage,
      workspace_ref: handle&.workspace_ref || legacy_workspace_ref_for(agent_run),
      tags: {
        "paid.agent_run_id" => agent_run.id.to_s,
        "paid.project_id" => agent_run.project_id.to_s
      },
      metadata: (resource.metadata || {}).merge("agent_run_status" => agent_run.status)
    )
    resource.reactivate!
    resource.reduced_confidence = false if resource.reduced_confidence?
    resource.save!
    resource
  end

  def self.schedule_cleanup_for!(agent_run:)
    return unless safe_agent_run_id(agent_run).present?

    resource = environments.find_by(agent_run: agent_run) || track_environment!(agent_run:)
    return unless resource
    return resource if resource.cleaned?

    resource.mark_cleanup_pending!
    resource
  end

  def self.record_cleanup_failure_for!(agent_run:, error:)
    return unless safe_agent_run_id(agent_run).present?

    environments.find_by(agent_run: agent_run)&.record_cleanup_failure!(error:)
  end

  def self.mark_cleaned_for!(agent_run:)
    return unless safe_agent_run_id(agent_run).present?

    environments.find_by(agent_run: agent_run)&.mark_cleaned!
  end

  def self.cleanup_retry_delay(attempt)
    [ CLEANUP_BASE_DELAY * (2**[ attempt - 1, 0 ].max), CLEANUP_MAX_DELAY ].min
  end

  def environment?
    resource_type == "environment"
  end

  def workspace?
    resource_type == "workspace"
  end

  def active?
    state == "active"
  end

  def cleanup_pending?
    state == "cleanup_pending"
  end

  def cleaned?
    state == "cleaned"
  end

  def runner_handle_object
    return if runner_handle.blank?

    ExecutionRunners::RunnerHandle.from_json(runner_handle)
  end

  def to_tracked_resource
    ExecutionRunners::TrackedResource.new(
      runner_type: runner_type.to_sym,
      resource_type: resource_type,
      identifier: identifier,
      host: host,
      workspace_ref: workspace_ref,
      tags: tags || {},
      metadata: metadata || {}
    )
  end

  def mark_cleanup_pending!
    # Default to a small future offset on first transition so a concurrent
    # reconcile cron tick does not see the row as `due_for_cleanup?` while the
    # caller is still in the middle of provider cleanup (AgentRun#cleanup_container
    # and AgentRunResourceJanitorJob both schedule → cleanup → mark_cleaned
    # without holding the row lock, and the runner's `cleanup` is otherwise
    # re-entered — a Docker::Error::NotFoundError on the second pass would race
    # with the imminent `mark_cleaned!` via `record_cleanup_failure!`).
    # `record_cleanup_failure!` always writes its own backoff, so subsequent
    # retries are unaffected.
    update!(
      state: "cleanup_pending",
      next_cleanup_at: next_cleanup_at || (Time.current + CLEANUP_BASE_DELAY),
      cleaned_at: nil
    )
  end

  def record_cleanup_failure!(error:)
    attempts = cleanup_attempts.to_i + 1
    update!(
      state: "cleanup_pending",
      cleanup_attempts: attempts,
      next_cleanup_at: Time.current + self.class.cleanup_retry_delay(attempts),
      last_cleanup_error: error.message.to_s.truncate(500),
      last_cleanup_error_class: error.class.name,
      last_cleanup_failed_at: Time.current,
      cleaned_at: nil
    )
  end

  def mark_reconciled!(reduced_confidence: self.reduced_confidence)
    update!(reconciled_at: Time.current, reduced_confidence: reduced_confidence)
  end

  def mark_cleaned!
    update!(
      state: "cleaned",
      cleaned_at: Time.current,
      reconciled_at: Time.current,
      next_cleanup_at: nil,
      last_cleanup_error: nil,
      last_cleanup_error_class: nil,
      last_cleanup_failed_at: nil
    )
    clear_agent_run_references!
  end

  def reactivate!
    self.state = "active"
    self.cleaned_at = nil
    self.next_cleanup_at = nil
    self.cleanup_attempts = 0
    self.last_cleanup_error = nil
    self.last_cleanup_error_class = nil
    self.last_cleanup_failed_at = nil
  end

  private

  def populate_owner_fields_from_agent_run
    return unless agent_run

    self.project ||= agent_run.project
    self.account ||= agent_run.project.account
  end

  def normalize_host
    self.host = host.to_s
  end

  def clear_agent_run_references!
    return unless environment? && agent_run

    stored_handle = ExecutionRunners::RunnerHandle.from_record(agent_run)
    container_matches = agent_run.container_id == identifier
    handle_matches = stored_handle&.identifier == identifier

    updates = {}
    updates[:container_id] = nil if container_matches
    updates[:runner_handle] = nil if handle_matches
    if container_matches || (handle_matches && agent_run.container_id.blank?)
      updates[:container_host] = nil
    end
    agent_run.update_columns(updates) if updates.any?
  end

  def self.legacy_workspace_ref_for(agent_run)
    return if agent_run.worktree_path.present?

    ExecutionRunners::LocalDockerRunner.workspace_volume_name_for(agent_run.id)
  end
  private_class_method :legacy_workspace_ref_for

  def self.build_legacy_handle(agent_run:, identifier:, host:)
    ExecutionRunners::RunnerHandle.new(
      runner_type: :local_docker,
      identifier: identifier,
      host: normalize_provider_host(host || agent_run.workspace_volume_host),
      workspace_ref: legacy_workspace_ref_for(agent_run),
      metadata: {
        "agent_run_id" => agent_run.id,
        "worktree_path" => agent_run.worktree_path,
        "environment" => agent_run.service_environment || {}
      }
    )
  end
  private_class_method :build_legacy_handle

  def self.normalize_provider_host(host)
    host.to_s.presence || "local"
  end
  private_class_method :normalize_provider_host

  def self.safe_agent_run_id(agent_run)
    return nil unless agent_run.is_a?(AgentRun)

    agent_run.id
  rescue NoMethodError
    nil
  end
  private_class_method :safe_agent_run_id
end
