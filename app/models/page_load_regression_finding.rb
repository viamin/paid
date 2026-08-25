# frozen_string_literal: true

# A confirmed page load regression on a pull request.
#
# A pull request holds at most one open finding per route (enforced by a
# partial unique index): a later capture that still shows the route regressed
# updates the finding rather than opening a second one. `actionable` records
# whether the route was in the capture's screenshot hints — only findings for
# pages the pull request actually touched can drive a follow-up run.
#
# @spec PAGE-LOAD-REGRESSION-005, PAGE-LOAD-REGRESSION-009
class PageLoadRegressionFinding < ApplicationRecord
  STATUSES = %w[open resolved superseded].freeze
  # Each queued follow-up counts an attempt. Without a cap, a regression the
  # agent cannot fix requeues on every scan cycle: each run pushes a commit, so
  # the generic no-progress loop breaker reads it as progress and never fires.
  MAX_FOLLOWUP_ATTEMPTS = 2

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :pull_request_number, :route_name, :comparison_metric, presence: true
  validates :baseline_ms, :current_ms, :delta_ms, :delta_ratio, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :open_findings, -> { where(status: "open") }
  scope :followup_eligible, -> { where(followup_attempts: ...MAX_FOLLOWUP_ATTEMPTS) }
  scope :actionable, -> { where(actionable: true) }
  scope :for_pull_request, ->(number) { where(pull_request_number: number) }

  # @spec PAGE-LOAD-FOLLOWUP-006
  def followup_exhausted?
    followup_attempts >= MAX_FOLLOWUP_ATTEMPTS
  end

  def record_followup_attempt!
    increment!(:followup_attempts)
  end

  def resolve!
    update!(status: "resolved", resolved_at: Time.current)
  end

  def supersede!
    update!(status: "superseded", resolved_at: Time.current)
  end

  # The payload a follow-up run's prompt is built from. Copied onto the run at
  # queue time so the prompt never re-measures or re-queries. The finding id
  # is the immutable identity the queue activity re-binds to: the same route
  # can later reopen as a new row, but an id never shifts.
  # @spec PAGE-LOAD-FOLLOWUP-004
  def evidence
    {
      "finding_id" => id,
      "route_name" => route_name,
      "route_path" => route_path,
      "comparison_metric" => comparison_metric,
      "baseline_ms" => baseline_ms,
      "current_ms" => current_ms,
      "delta_ms" => delta_ms,
      "delta_ratio" => delta_ratio.to_f,
      "baseline_commit_sha" => baseline_commit_sha,
      "commit_sha" => commit_sha,
      "sample_spread" => sample_spread,
      "changed_files" => changed_files
    }
  end
end
