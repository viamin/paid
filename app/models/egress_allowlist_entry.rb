# frozen_string_literal: true

require "ipaddr"

# Tenant-managed egress allowlist entry (RDR-055). Entries with a nil
# project_id apply account-wide; project-scoped entries extend the account
# set. Domain rules only — validation rejects paths, userinfo, ports in the
# pattern, wildcards beyond a single leading label, IP literals, localhost,
# and wildcard TLDs.
# @spec EGRESS-POLICY-001
class EgressAllowlistEntry < ApplicationRecord
  include TenantScoped
  has_logidze

  SOURCE_KINDS = %w[tenant platform operator_override].freeze
  SCHEMES = %w[http https].freeze
  LOOPBACK_LITERALS = %w[localhost localhost.localdomain].freeze
  METADATA_IPS = %w[169.254.169.254 fd00:ec2::254].freeze
  INVALID_HOST_PATTERN_MESSAGE = "Host pattern must be a hostname (e.g. api.example.com) or leading-wildcard subdomain (e.g. *.packages.example.com)."

  belongs_to :project, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  has_many :egress_security_events, dependent: :nullify

  scope :enabled, -> { where(enabled: true) }
  scope :disabled, -> { where(enabled: false) }
  scope :account_wide, -> { where(project_id: nil) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :ordered, -> { order(:host_pattern, :scheme, :port) }

  before_validation :normalize_host_pattern
  before_validation :stamp_disabled_at

  validates :account, presence: true
  validates :host_pattern, presence: true, length: { maximum: AgentRuns::EgressPolicy::HostPattern::MAX_HOST_LENGTH }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :scheme, inclusion: { in: SCHEMES, message: "must be http or https" }, allow_nil: true
  validate :port_in_valid_range
  validate :host_pattern_shape
  validate :project_belongs_to_account, if: -> { project.present? }
  validate :host_pattern_uniqueness_within_scope

  def account_level?
    project_id.nil?
  end

  def project_level?
    project_id.present?
  end

  def matches?(host:, scheme: nil, port: nil)
    return false unless enabled?
    return false if scheme.present? && self.scheme.present? && self.scheme != scheme
    return false if port.present? && self.port.present? && self.port != port

    AgentRuns::EgressPolicy::HostPattern.matches?(host_pattern, host)
  end

  def normalized_host_pattern
    host_pattern.to_s.strip.downcase
  end

  def self.host_pattern_valid?(value)
    AgentRuns::EgressPolicy::HostPattern.invalid_reason(value).nil?
  end

  # Rejection reason for the stored row, or nil when safe. Used by policy
  # resolution to defensively re-validate persisted rows before a container
  # starts (write-time validation alone cannot cover legacy or manual rows).
  # Checks host_pattern, port, and scheme -- the same fields validated at
  # write-time -- so this stays the single source of truth for "is this
  # entry safe" rather than drifting from a second implementation.
  # @spec EGRESS-POLICY-001
  def unsafe_reason
    AgentRuns::EgressPolicy::HostPattern.invalid_reason(host_pattern) ||
      port_unsafe_reason ||
      scheme_unsafe_reason
  end

  private

  def port_unsafe_reason
    "port must be between 1 and 65535" if port.present? && !port.to_i.between?(1, 65_535)
  end

  def scheme_unsafe_reason
    "scheme must be http or https" if scheme.present? && SCHEMES.exclude?(scheme.to_s)
  end

  def normalize_host_pattern
    self.host_pattern = normalized_host_pattern if host_pattern.present?
  end

  def stamp_disabled_at
    return unless will_save_change_to_enabled?

    self.disabled_at = enabled ? nil : (disabled_at || Time.current)
  end

  def port_in_valid_range
    return if port.nil? || port.to_i.between?(1, 65_535)

    errors.add(:port, "must be between 1 and 65535")
  end

  def host_pattern_shape
    return if host_pattern.blank?

    reason = unsafe_reason
    errors.add(:host_pattern, validation_message_for_host_pattern(reason)) if reason
  end

  def validation_message_for_host_pattern(reason)
    case reason
    when nil
      nil
    when "must not target localhost"
      "Loopback hosts (e.g. localhost) are not allowed."
    when "must not be an IP literal"
      ip_literal_validation_message
    when "must have at least two host labels"
      wildcard_tld?(normalized_host_pattern) ? "Wildcard top-level domains (e.g. *.com) are not allowed." : INVALID_HOST_PATTERN_MESSAGE
    when "top-level domain must be at least two alphabetic characters"
      normalized_host_pattern.start_with?("*.") ? "Wildcard top-level domains (e.g. *.com) are not allowed." : INVALID_HOST_PATTERN_MESSAGE
    when /\Awildcard/
      "Wildcard host patterns are not allowed."
    else
      INVALID_HOST_PATTERN_MESSAGE
    end
  end

  def ip_literal_validation_message
    ip = parse_ip_literal
    return INVALID_HOST_PATTERN_MESSAGE unless ip
    return "Cloud metadata service addresses are not allowed." if metadata_ip?(ip)
    return "Loopback hosts (e.g. localhost) are not allowed." if ip.loopback?
    return "Private network and link-local addresses must be added by an operator, not via the tenant allowlist." if ip.private? || ip.link_local?

    INVALID_HOST_PATTERN_MESSAGE
  end

  def parse_ip_literal
    IPAddr.new(normalized_host_pattern.delete_prefix("*."))
  rescue IPAddr::Error
    nil
  end

  def metadata_ip?(ip)
    METADATA_IPS.any? { |address| IPAddr.new(address) == ip }
  end

  def wildcard_tld?(pattern)
    return false unless pattern.start_with?("*.")

    pattern.delete_prefix("*.").exclude?(".")
  end

  def project_belongs_to_account
    return unless account_id && project.account_id != account_id

    errors.add(:project, "must belong to the same account")
  end

  def host_pattern_uniqueness_within_scope
    return if host_pattern.blank?

    scope = self.class.where(account_id: account_id, project_id: project_id, host_pattern: host_pattern, scheme: scheme, port: port)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:host_pattern, "already exists in this scope") if scope.exists?
  end
end
