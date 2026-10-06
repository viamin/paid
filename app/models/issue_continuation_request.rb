# frozen_string_literal: true

# A scoped authorization to deliberately continue an issue past its prior
# terminal closeout evidence (merged partial PR / no-code-required outcome).
#
# The request persists the actor, a required reason, and the
# outcome-generation identity (evidence snapshot + digest) it authorizes
# against. One open request is allowed per issue (partial unique index), and
# the request and its queued AgentRun are created in a single transaction by
# Issues::RequestContinuation, so double-clicks, replays, and concurrent
# requests queue at most one run. When the run reaches a terminal status the
# request closes as consumed and the terminal guards re-arm — the issue is
# deliberately continued once per request (#4120).
# @spec PARTIAL-CLOSEOUT-003
class IssueContinuationRequest < ApplicationRecord
  STATUSES = %w[queued consumed superseded].freeze
  OPEN_STATUSES = %w[queued].freeze

  belongs_to :issue
  belongs_to :project
  belongs_to :requested_by, class_name: "User"
  has_many :agent_runs, foreign_key: :continuation_request_id, inverse_of: :continuation_request, dependent: :nullify

  validates :reason, presence: true, length: { maximum: 2000 }
  validates :status, inclusion: { in: STATUSES }
  validates :evidence_digest, presence: true

  scope :open, -> { where(status: OPEN_STATUSES) }
  scope :closed, -> { where.not(status: OPEN_STATUSES) }

  after_commit :bump_inbox_cache_version, on: [ :create, :update ]

  def self.open_for_issue(issue)
    open.where(issue: issue).last
  end

  def open?
    status.in?(OPEN_STATUSES)
  end

  # Closes the authorization because its run finished; the terminal guards
  # re-arm, so continuing again requires a fresh deliberate request.
  def consume!(run_status:)
    return unless open?

    update!(status: "consumed", closed_at: Time.current, closure_reason: "run terminal status: #{run_status}")
  end

  # Closes the authorization because it no longer matches the world it was
  # issued against (changed evidence generation, explicit pause, lost
  # admission) — the run it authorized is cancelled by the caller.
  def supersede!(reason:)
    return unless open?

    update!(status: "superseded", closed_at: Time.current, closure_reason: reason)
  end

  private

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(issue.project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end
end
