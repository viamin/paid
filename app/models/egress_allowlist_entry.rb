# frozen_string_literal: true

require "ipaddr"

# Tenant-managed entry in the agent container egress allowlist.
#
# Each entry resolves into one or more destinations in an agent run's egress
# policy snapshot. The model intentionally restricts what counts as a safe
# tenant rule: exact hostnames and leading-wildcard subdomains only, with
# optional scheme/port filters. Broader patterns (wildcard TLDs, IP literals,
# paths, userinfo) are rejected at the model boundary so the UI/API can
# surface actionable validation errors.
#
# The {RDR-055} source-of-truth for the design lives at
# `docs/rdrs/RDR-055-agent-container-egress-allowlisting.md`.
class EgressAllowlistEntry < ApplicationRecord
  include TenantScoped

  SOURCE_KINDS = %w[tenant platform operator_override].freeze
  SCHEMES = %w[http https].freeze

  belongs_to :project, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  has_many :egress_security_events, dependent: :nullify

  before_validation :normalize_host_pattern
  before_validation :stamp_disabled_at

  validates :host_pattern, presence: true, length: { maximum: 255 }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :scheme, inclusion: { in: SCHEMES, allow_nil: true }
  validate :port_in_valid_range
  validate :host_pattern_is_safe
  validate :project_belongs_to_account, if: -> { project.present? }
  validate :host_pattern_uniqueness_within_scope

  scope :enabled, -> { where(enabled: true) }
  scope :disabled, -> { where(enabled: false) }
  scope :for_account, ->(account) { where(account: account, project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }
  scope :ordered, -> { order(:host_pattern, :scheme, :port) }

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

    pattern = normalized_host_pattern
    target = host.to_s.strip.downcase
    return false if target.blank?

    if pattern.start_with?("*.")
      suffix = pattern[2..]
      target.end_with?(".#{suffix}") && target != suffix
    else
      target == pattern
    end
  end

  def normalized_host_pattern
    host_pattern.to_s.strip.downcase
  end

  # Class-level helper exposed for callers that need to share the safety
  # rules without instantiating a model. Returns true only when the input
  # is a non-empty string that matches the host pattern grammar.
  def self.host_pattern_valid?(value)
    return false if value.blank?

    str = value.to_s.strip.downcase
    return false if str.length > 255
    return false if str.start_with?(".")
    return false if str.end_with?(".")
    return false if ip_literal?(str.delete_prefix("*."))

    if str.start_with?("*.")
      remainder = str[2..]
      return false if remainder.blank? || remainder.start_with?(".")
      labels = remainder.split(".")
      return false if labels.size < 2

      labels_valid?(labels)
    else
      return false if str.include?("*")
      labels = str.split(".")
      return false if labels.size < 2

      labels_valid?(labels)
    end
  end

  # Shared per-label safety checks for both exact-host and wildcard
  # patterns: label charset, leading/trailing hyphens, the 63-char label
  # limit, and the TLD (last label) minimum length. One copy so the two
  # grammar branches cannot drift apart.
  def self.labels_valid?(labels)
    return false if labels.any? { |label| label.start_with?("-") || label.end_with?("-") || label.length > 63 }
    return false if labels.any? { |label| label !~ /\A[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\z/ }
    return false if labels.last.length < 2

    true
  end
  private_class_method :labels_valid?

  # Patterns and rationale for what counts as a safe tenant rule. Wildcard
  # TLDs, embedded paths, userinfo, IP literals, and loopback/metadata
  # addresses are intentionally excluded so the UI/API can surface a
  # concrete validation message rather than silently accepting a request
  # that would otherwise be rejected downstream.
  LOOPBACK_LITERALS = %w[localhost localhost.localdomain].freeze
  RESERVED_TLDS = %w[local test invalid example].freeze
  REJECT_REASONS = {
    blank: "Host pattern is required.",
    too_long: "Host pattern must be 255 characters or fewer.",
    invalid_format: "Host pattern must be a hostname (e.g. api.example.com) or leading-wildcard subdomain (e.g. *.packages.example.com).",
    wildcard_tld: "Wildcard top-level domains (e.g. *.com) are not allowed.",
    wildcard_internal: "Wildcard host patterns are not allowed.",
    loopback: "Loopback hosts (e.g. localhost) are not allowed.",
    private_ip: "Private network and link-local addresses must be added by an operator, not via the tenant allowlist.",
    metadata_ip: "Cloud metadata service addresses are not allowed."
  }.freeze

  METADATA_ADDRESSES = %w[169.254.169.254 fd00:ec2::254].freeze

  def self.ip_literal?(str)
    IPAddr.new(str)
    true
  rescue IPAddr::Error
    false
  end
  private_class_method :ip_literal?

  private

  def normalize_host_pattern
    self.host_pattern = host_pattern.to_s.strip.downcase if host_pattern.present?
  end

  def stamp_disabled_at
    if enabled_changed? && !enabled
      self.disabled_at ||= Time.current
    elsif enabled_changed? && enabled
      self.disabled_at = nil
    end
  end

  def port_in_valid_range
    return if port.nil?

    errors.add(:port, "must be between 1 and 65535") unless port.between?(1, 65_535)
  end

  def host_pattern_is_safe
    return if host_pattern.blank?

    tld = host_pattern.split(".").last.to_s
    suffix = host_pattern.delete_prefix("*.")
    suffix_labels = suffix.split(".")

    if LOOPBACK_LITERALS.include?(host_pattern) || suffix == "localhost"
      errors.add(:host_pattern, REJECT_REASONS[:loopback])
    end

    if host_pattern.start_with?("*.") && suffix_labels.size < 2
      errors.add(:host_pattern, REJECT_REASONS[:wildcard_tld])
    end

    if host_pattern.start_with?("*.") && suffix_labels.any? { |label| label == "*" }
      errors.add(:host_pattern, REJECT_REASONS[:wildcard_internal])
    end

    if !host_pattern.start_with?("*.") && RESERVED_TLDS.include?(tld)
      errors.add(:host_pattern, REJECT_REASONS[:invalid_format])
    end

    reject_ip_literal(suffix)

    unless self.class.host_pattern_valid?(host_pattern)
      existing = errors[:host_pattern]
      if existing.empty?
        errors.add(:host_pattern, REJECT_REASONS[:invalid_format])
      end
    end
  end

  def reject_ip_literal(candidate)
    ip = IPAddr.new(candidate)

    if METADATA_ADDRESSES.any? { |addr| IPAddr.new(addr) == ip }
      errors.add(:host_pattern, REJECT_REASONS[:metadata_ip])
    elsif ip.loopback?
      errors.add(:host_pattern, REJECT_REASONS[:loopback])
    elsif ip.private? || ip.link_local?
      errors.add(:host_pattern, REJECT_REASONS[:private_ip])
    else
      errors.add(:host_pattern, REJECT_REASONS[:invalid_format])
    end
  rescue IPAddr::Error
    nil
  end

  def project_belongs_to_account
    return unless project && account_id

    if project.account_id != account_id
      errors.add(:project, "must belong to the same account")
    end
  end

  def host_pattern_uniqueness_within_scope
    return if host_pattern.blank?

    scope = self.class.where(account_id: account_id, host_pattern: host_pattern, scheme: scheme, port: port)
    scope = scope.where.not(id: id) if persisted?
    if project_id.present?
      scope = scope.where(project_id: project_id)
    else
      scope = scope.where(project_id: nil)
    end

    if scope.exists?
      errors.add(:host_pattern, "already exists in this scope")
    end
  end
end
