# frozen_string_literal: true

class DockerHost < ApplicationRecord
  has_logidze

  BACKEND_TYPES = %w[local remote swarm].freeze
  READINESS_STATUSES = %w[unknown ready failing disabled draining].freeze
  STATUS_TYPES = %w[unknown ready missing failing].freeze

  belongs_to :account

  encrypts :client_ca_pem
  encrypts :client_ca_key_pem
  encrypts :client_certificate_pem
  encrypts :client_private_key_pem
  encrypts :server_certificate_pem
  encrypts :server_private_key_pem
  encrypts :server_csr_pem

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(enabled: :desc, display_name: :asc, identifier: :asc) }
  PRIMARY_NETWORK_NAME = NetworkPolicy::NETWORK_NAME

  # @spec EXEC-DISABLE-004
  # @spec CONTAINER-RUNTIME-030
  #
  # required_infra_network_status is only ever verified (and set to "ready")
  # by the remote guided setup helpers (DockerHosts::SetupActionRunner), so
  # it is scoped to remote hosts here. Local hosts never go through that
  # wizard; their paid_internal network readiness is instead checked live at
  # run time (Containers::HostReadiness, NetworkPolicy.ensure_network!)
  # rather than cached on the record. Gating on this column for local hosts
  # would leave them permanently unable to reach placement-ready.
  scope :placement_ready_for_agent_runs, lambda {
    enabled
      .where(
        readiness_status: "ready",
        image_status: "ready",
        required_network_status: "ready"
      )
      .where("backend_type <> 'remote' OR required_infra_network_status = 'ready'")
      .where.not(id: ExecutionControl.enabled.where(scope: "backend").select(:docker_host_id))
  }

  # Identifiers (scoped to a single account, since identifier is only unique
  # per-account) of backends with an active backend-scoped execution control.
  #
  # @spec EXEC-DISABLE-004
  # placement_ready_for_agent_runs only guards run creation/options
  # (Containers::ResolveHostForRun). Queued runs carry a stored host
  # selection (or fall through to the registry default) and are dispatched
  # by Containers::BackendScheduler against Containers.host_registry, which
  # has no visibility into ExecutionControl rows — so BackendScheduler must
  # reject candidates against this set at dispatch time too, or a run queued
  # before (or without) the control would still start on a disabled backend.
  def self.disabled_placement_identifiers(account_id)
    ExecutionControl.enabled.where(scope: "backend")
      .joins(:docker_host)
      .where(docker_hosts: { account_id: account_id })
      .pluck("docker_hosts.identifier").to_set
  end

  before_validation :normalize_fields
  before_validation :sync_disabled_state
  after_save :clear_stale_host_preferences, if: -> { saved_change_to_enabled?(from: true, to: false) }

  validates :identifier, presence: true, uniqueness: { scope: :account_id }, length: { maximum: 64 },
    format: { with: /\A[a-z0-9][a-z0-9_-]*\z/, message: "must use lowercase letters, numbers, dashes, or underscores" }
  validates :display_name, presence: true, length: { maximum: 100 }
  validates :backend_type, presence: true, inclusion: { in: BACKEND_TYPES }
  validates :callback_url, presence: true, length: { maximum: 500 }
  validates :endpoint, length: { maximum: 500 }, allow_blank: true
  validates :image_tag, presence: true, length: { maximum: 255 }
  validates :required_network_name, length: { maximum: 255 }, allow_blank: true
  validates :manual_concurrency_limit,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 10_000 }
  validates :readiness_status, inclusion: { in: READINESS_STATUSES }
  validates :image_status, inclusion: { in: STATUS_TYPES }
  validates :required_network_status, inclusion: { in: STATUS_TYPES }
  validates :required_infra_network_status, inclusion: { in: STATUS_TYPES }
  validate :identifier_immutable, if: -> { persisted? && will_save_change_to_identifier? }
  validate :local_backend_endpoint_rules

  def local?
    backend_type == "local"
  end

  def remote?
    backend_type == "remote"
  end

  def ready?
    readiness_status == "ready"
  end

  def disabled?
    !enabled?
  end

  def available_slots(active_run_count:)
    [ manual_concurrency_limit - active_run_count.to_i, 0 ].max
  end

  def client_tls_material_present?
    [ client_ca_pem, client_certificate_pem, client_private_key_pem ].all?(&:present?)
  end

  def setup_profile
    setup_state.fetch("profile", "generic_linux")
  end

  def setup_step(key)
    setup_state.fetch("steps", {}).fetch(key.to_s, {})
  end

  # @spec CONTAINER-RUNTIME-030
  # See placement_ready_for_agent_runs for why required_infra_network_status
  # only gates remote hosts.
  def placement_ready?
    enabled? && ready? && image_status == "ready" && required_network_status == "ready" &&
      (!remote? || required_infra_network_status == "ready")
  end

  def disable!
    update!(enabled: false)
  end

  def endpoint_label
    local? ? "Local Docker" : endpoint.presence || "Not configured"
  end

  private

  def normalize_fields
    self.identifier = identifier.to_s.strip.downcase.presence
    self.display_name = display_name.to_s.strip.presence
    self.endpoint = endpoint.to_s.strip.presence
    self.callback_url = callback_url.to_s.strip.presence
    self.image_tag = image_tag.to_s.strip.presence || "paid-agent:latest"
    # Remote setup/readiness must stay pinned to the runtime contract's
    # restricted network. Allowing arbitrary names here would make the
    # record's cached "required_network_status" prove a network the runtime
    # never uses.
    self.required_network_name = PRIMARY_NETWORK_NAME
    self.backend_type = backend_type.to_s.strip.presence || "local"
    self.readiness_status = readiness_status.to_s.strip.presence || "unknown"
    self.image_status = image_status.to_s.strip.presence || "unknown"
    self.required_network_status = required_network_status.to_s.strip.presence || "unknown"
    self.required_infra_network_status = required_infra_network_status.to_s.strip.presence || "unknown"
    self.failing_check = failing_check.to_s.strip.presence
    self.daemon_architecture = daemon_architecture.to_s.strip.presence
    self.daemon_summary = daemon_summary.to_s.strip.presence
    self.last_error = last_error.to_s.strip.presence
  end

  def sync_disabled_state
    if enabled?
      self.disabled_at = nil
      self.readiness_status = "unknown" if readiness_status == "disabled"
    else
      self.disabled_at ||= Time.current
      self.readiness_status = "disabled"
    end
  end

  def local_backend_endpoint_rules
    if local? && endpoint.present?
      errors.add(:endpoint, "must be blank for the local Docker host")
    elsif !local? && endpoint.blank?
      errors.add(:endpoint, "can't be blank for remote Docker hosts")
    end
  end

  def identifier_immutable
    errors.add(:identifier, "can't be changed after creation")
  end

  def clear_stale_host_preferences
    TenantSetting.where(account_id: account_id, preferred_docker_host_identifier: identifier)
      .update_all(preferred_docker_host_identifier: nil, updated_at: Time.current)
    Project.where(account_id: account_id, preferred_docker_host_identifier: identifier)
      .update_all(preferred_docker_host_identifier: nil, updated_at: Time.current)
  end

  def setup_state
    metadata.fetch("setup", {}).deep_stringify_keys
  end
end
