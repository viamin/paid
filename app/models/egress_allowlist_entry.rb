# frozen_string_literal: true

# Tenant-managed egress allowlist entry (RDR-055). Entries with a nil
# project_id apply account-wide; project-scoped entries extend the account
# set. Domain rules only — validation rejects paths, userinfo, ports in the
# pattern, wildcards beyond a single leading label, IP literals, localhost,
# and wildcard TLDs.
# @spec EGRESS-POLICY-001
class EgressAllowlistEntry < ApplicationRecord
  belongs_to :account
  belongs_to :project, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  scope :enabled, -> { where(enabled: true) }
  scope :account_wide, -> { where(project_id: nil) }
  scope :for_project, ->(project) { where(project: project) }

  validates :account, presence: true
  validates :host_pattern, presence: true, length: { maximum: AgentRuns::EgressPolicy::HostPattern::MAX_HOST_LENGTH }
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 65_535 }, allow_nil: true
  validates :scheme, inclusion: { in: %w[http https], message: "must be http or https" }, allow_nil: true
  validate :host_pattern_shape
  validate :project_belongs_to_account
  validate :unique_within_scope

  before_validation :normalize_host_pattern

  # Rejection reason for the stored pattern, or nil when safe. Used by policy
  # resolution to defensively re-validate persisted rows before a container
  # starts (write-time validation alone cannot cover legacy or manual rows).
  # @spec EGRESS-POLICY-001
  def unsafe_reason
    AgentRuns::EgressPolicy::HostPattern.invalid_reason(host_pattern)
  end

  private

  def normalize_host_pattern
    self.host_pattern = host_pattern.to_s.strip.downcase if host_pattern.is_a?(String)
  end

  def host_pattern_shape
    reason = unsafe_reason
    errors.add(:host_pattern, reason) if reason
  end

  def project_belongs_to_account
    return if project_id.nil?
    return if project.nil? || project.account_id == account_id

    errors.add(:project, "must belong to the same account as the entry")
  end

  def unique_within_scope
    scope = self.class
      .where(account_id: account_id, project_id: project_id, host_pattern: host_pattern, port: port, scheme: scheme)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:host_pattern, "is already allowlisted for this scope") if scope.exists?
  end
end
