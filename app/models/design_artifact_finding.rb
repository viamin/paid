# frozen_string_literal: true

# Durable, operator-visible result of reconciling one repository design
# artifact at one immutable revision against the locally synchronized issue set.
# @spec DESIGN-RECONCILIATION-001
class DesignArtifactFinding < ApplicationRecord
  STATES = %w[missing_tree partial_tree stale_metadata deferred unverifiable].freeze
  STATUSES = %w[open assigned deferred dismissed resolved].freeze
  # One shared actionability contract (also reused by
  # ReconcileDesignArtifacts::Result#actionable_findings): a finding whose
  # state is informational records an intentional artifact status. It is kept
  # for inspection but implies no concrete human action, so it never enters
  # the Inbox lane, badge, filters, or supported API action listings.
  # @spec OPERATOR-INBOX-020
  INFORMATIONAL_STATES = %w[deferred].freeze

  belongs_to :account
  belongs_to :project

  validates :artifact_path, :revision, :fingerprint, :state, :status, :covered_at, presence: true
  validates :fingerprint, uniqueness: { scope: :project_id }
  validates :state, inclusion: { in: STATES }
  validates :status, inclusion: { in: STATUSES }

  after_commit :bump_inbox_cache_version, if: :inbox_visibility_changed?

  scope :open_findings, -> { where(status: "open") }
  scope :pending_findings, -> { where(status: %w[open assigned deferred dismissed]) }
  scope :actionable_findings, -> { open_findings.where.not(state: INFORMATIONAL_STATES) }

  belongs_to :resolution_actor, class_name: "User", optional: true
  belongs_to :resolution_issue, class_name: "Issue", optional: true

  class << self
    def actionable_state?(state) = !INFORMATIONAL_STATES.include?(state)

    def informational_state?(state) = INFORMATIONAL_STATES.include?(state)
  end

  def resolve!
    update!(status: "resolved", resolved_at: Time.current)
  end

  def decision_pending?
    status.in?(%w[assigned deferred dismissed])
  end

  def informational? = !self.class.actionable_state?(state)

  def unverifiable? = state == "unverifiable"

  private

  def inbox_visibility_changed?
    return status == "open" if previously_new_record?

    saved_change_to_status? && (status_before_last_save == "open" || status == "open")
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
