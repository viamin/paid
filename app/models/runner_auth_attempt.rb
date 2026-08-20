# frozen_string_literal: true

# RDR-041 / #2960 — durable per-attempt telemetry for runner subscription auth.
#
# Each row captures one attempt to materialize, refresh, lease, harvest, or
# evaluate eligibility for a subscription runner's auth on a specific container
# host. The schema is intentionally narrow: it answers "managed vs host" and
# "remote vs local" comparisons without storing tokens, native files,
# authorization codes, or refresh tokens. Non-secret context (provider key,
# backend capability, feature-flag state, refresh/lease/result codes, timing,
# retry count) lives in dedicated columns so analytics queries can group by
# provider, auth_source, and container_host without scanning a free-form JSON
# payload.
class RunnerAuthAttempt < ApplicationRecord
  include SecretSafeMetadata

  STAGE_ELIGIBILITY = "eligibility".freeze
  STAGE_MATERIALIZATION = "materialization".freeze
  STAGE_REFRESH = "refresh".freeze
  STAGE_LEASE = "lease".freeze
  STAGE_HARVEST = "harvest".freeze
  STAGES = [
    STAGE_ELIGIBILITY,
    STAGE_MATERIALIZATION,
    STAGE_REFRESH,
    STAGE_LEASE,
    STAGE_HARVEST
  ].freeze

  AUTH_SOURCE_MANAGED = "managed".freeze
  AUTH_SOURCE_HOST_FORWARDED = "host_forwarded".freeze
  AUTH_SOURCE_API_KEY_PROXY = "api_key_proxy".freeze
  AUTH_SOURCE_NONE = "none".freeze
  AUTH_SOURCES = [
    AUTH_SOURCE_MANAGED,
    AUTH_SOURCE_HOST_FORWARDED,
    AUTH_SOURCE_API_KEY_PROXY,
    AUTH_SOURCE_NONE
  ].freeze

  MATERIALIZE_ENV = Runners::SubscriptionAuthMaterializers::MATERIALIZE_ENV
  MATERIALIZE_NATIVE_FILE = Runners::SubscriptionAuthMaterializers::MATERIALIZE_NATIVE_FILE
  MATERIALIZE_HOST_MOUNT = Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT
  MATERIALIZE_UNSUPPORTED = Runners::SubscriptionAuthMaterializers::MATERIALIZE_UNSUPPORTED
  MATERIALIZATION_MODES = [
    MATERIALIZE_ENV,
    MATERIALIZE_NATIVE_FILE,
    MATERIALIZE_HOST_MOUNT,
    MATERIALIZE_UNSUPPORTED
  ].freeze

  RESULT_MATERIALIZED = "materialized".freeze
  RESULT_SKIPPED = "skipped".freeze
  RESULT_FAILED = "failed".freeze
  RESULT_HARVESTED = "harvested".freeze
  RESULT_HARVEST_FAILED = "harvest_failed".freeze
  RESULT_REFRESHED = "refreshed".freeze
  RESULT_REFRESH_FAILED = "refresh_failed".freeze
  RESULT_EXPIRED = "expired".freeze
  RESULT_LEASE_ACQUIRED = "lease_acquired".freeze
  RESULT_LEASE_WAITED = "lease_waited".freeze
  RESULT_LEASE_TIMEOUT = "lease_timeout".freeze
  RESULTS = [
    RESULT_MATERIALIZED,
    RESULT_SKIPPED,
    RESULT_FAILED,
    RESULT_HARVESTED,
    RESULT_HARVEST_FAILED,
    RESULT_REFRESHED,
    RESULT_REFRESH_FAILED,
    RESULT_EXPIRED,
    RESULT_LEASE_ACQUIRED,
    RESULT_LEASE_WAITED,
    RESULT_LEASE_TIMEOUT
  ].freeze

  REFRESH_NOT_NEEDED = "not_needed".freeze
  REFRESH_REFRESHED = "refreshed".freeze
  REFRESH_REFRESH_FAILED = "refresh_failed".freeze
  REFRESH_EXPIRED = "expired".freeze
  REFRESH_NOT_APPLICABLE = "not_applicable".freeze
  REFRESH_STATES = [
    REFRESH_NOT_NEEDED,
    REFRESH_REFRESHED,
    REFRESH_REFRESH_FAILED,
    REFRESH_EXPIRED,
    REFRESH_NOT_APPLICABLE
  ].freeze

  LEASE_NONE = "none".freeze
  LEASE_ACQUIRED = "acquired".freeze
  LEASE_WAITED = "waited".freeze
  LEASE_TIMEOUT = "timeout".freeze
  LEASE_NOT_APPLICABLE = "not_applicable".freeze
  LEASE_STATES = [
    LEASE_NONE,
    LEASE_ACQUIRED,
    LEASE_WAITED,
    LEASE_TIMEOUT,
    LEASE_NOT_APPLICABLE
  ].freeze

  FLAG_ENABLED = "enabled".freeze
  FLAG_DISABLED = "disabled".freeze
  FLAG_UNREGISTERED = "unregistered".freeze
  FLAG_STATES = [ FLAG_ENABLED, FLAG_DISABLED, FLAG_UNREGISTERED ].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :runner_credential, optional: true

  before_validation :assign_project_from_agent_run
  before_validation :assign_account_from_project
  before_validation :assign_attempted_at
  before_validation :enforce_metadata_secret_safety
  before_validation :strip_unknown_metadata

  validates :runner_key, presence: true, length: { maximum: 64 }
  validates :attempt_stage, presence: true, inclusion: { in: STAGES }
  validates :auth_source, presence: true, inclusion: { in: AUTH_SOURCES }
  validates :materialization_mode, inclusion: { in: MATERIALIZATION_MODES }, allow_nil: true
  validates :result, presence: true, inclusion: { in: RESULTS }
  validates :refresh_state, inclusion: { in: REFRESH_STATES }, allow_nil: true
  validates :lease_state, inclusion: { in: LEASE_STATES }, allow_nil: true
  validates :feature_flag_state, inclusion: { in: FLAG_STATES }, allow_nil: true
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempted_at, presence: true
  validate :metadata_is_object
  validate :failure_reason_safe
  validate :project_matches_agent_run
  validate :account_matches_project

  scope :for_account, ->(account) { where(account: account) }
  scope :for_project, ->(project) { where(project: project) }
  scope :for_agent_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :for_runner_key, ->(runner_key) { where(runner_key: runner_key.to_s) }
  scope :for_auth_source, ->(auth_source) { where(auth_source: auth_source.to_s) }
  scope :for_container_host, ->(container_host) { where(container_host: container_host.to_s) }
  scope :successful, -> { where(result: SUCCESS_RESULTS) }
  scope :recent, -> { order(attempted_at: :desc, id: :desc) }
  scope :within, ->(from:, to:) {
    rel = all
    rel = rel.where("attempted_at >= ?", from) if from.present?
    rel = rel.where("attempted_at <= ?", to) if to.present?
    rel
  }

  SUCCESS_RESULTS = [
    RESULT_MATERIALIZED,
    RESULT_HARVESTED,
    RESULT_REFRESHED,
    RESULT_LEASE_ACQUIRED
  ].freeze

  FAILURE_RESULTS = [
    RESULT_FAILED,
    RESULT_HARVEST_FAILED,
    RESULT_REFRESH_FAILED,
    RESULT_EXPIRED,
    RESULT_LEASE_TIMEOUT
  ].freeze

  class SecretLeakError < StandardError; end

  def self.record!(**attrs)
    create!(attrs)
  end

  private

  def assign_project_from_agent_run
    self.project ||= agent_run&.project
  end

  # Auto-derive account from the resolved project so callers that build a
  # record with only `project` (or only `agent_run`) don't have to also
  # remember to thread the matching account through. If account is set
  # explicitly to a different tenant, account_matches_project below still
  # rejects it.
  def assign_account_from_project
    self.account ||= project&.account
  end

  def assign_attempted_at
    self.attempted_at ||= Time.current
  end

  def failure_reason_safe
    return if failure_reason.blank?

    if self.class.secret_like?(failure_reason) || failure_reason.length > 64
      errors.add(:failure_reason, "must be a short non-secret reason code")
    end
  end

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  # RLS only constrains projects.account_id = paid_current_account_id(); the
  # denormalized account_id on this row is the actual tenant key used by
  # Analytics::RunnerAuthAttempts::BaseQuery#account_ids. A caller that builds
  # `account: a, project: b_owned_by_other_account` would otherwise produce a
  # row whose account_id belongs to a different tenant than the project's
  # RLS-guarded lookup, so reject it here before persistence.
  def account_matches_project
    return unless account_id.present? && project_id.present? && project.present?

    errors.add(:account, "must match the project's account") if account_id != project.account_id
  end
end
