# frozen_string_literal: true

# Durable, operator-visible result of reconciling one repository design
# artifact at one immutable revision against the locally synchronized issue set.
# @spec DESIGN-RECONCILIATION-001
class DesignArtifactFinding < ApplicationRecord
  STATES = %w[missing_tree partial_tree stale_metadata deferred unverifiable].freeze
  STATUSES = %w[open resolved].freeze

  belongs_to :account
  belongs_to :project

  validates :artifact_path, :revision, :fingerprint, :state, :status, :covered_at, presence: true
  validates :fingerprint, uniqueness: { scope: :project_id }
  validates :state, inclusion: { in: STATES }
  validates :status, inclusion: { in: STATUSES }

  after_commit :bump_inbox_cache_version, if: :saved_change_to_open_status?

  scope :open_findings, -> { where(status: "open") }

  def resolve!
    update!(status: "resolved", resolved_at: Time.current)
  end

  private

  def saved_change_to_open_status?
    return status == "open" if previously_new_record?

    status_before_last_save == "open" || status == "open"
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
