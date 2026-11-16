# frozen_string_literal: true

# A projected stalled issue belonging to one successful checkpoint
# generation of the partial-closeout stall projection (#4912). The row is a
# display-only read model: `status` and `blockers` serialize the
# `Issues::CloseoutStatus` result the recomputation observed, and a
# successful recomputation atomically replaces every row of its project.
# It never grants a continuation and never mutates `paid_state`; live
# `DefaultCandidateSource.eligible_scope` stays the admission authority.
# @spec PARTIAL-CLOSEOUT-042
class StalledCloseoutProjectionRow < ApplicationRecord
  belongs_to :project
  belongs_to :issue

  # Rehydrates the recorded `Issues::CloseoutStatus::Result` so list, badge,
  # and filter consumers render the persisted outcome exactly as the live
  # lane evaluation would have.
  def status_result
    @status_result ||= build_status_result
  end

  private

  def build_status_result
    payload = status || {}
    evidence = payload.fetch("evidence", {})
    Issues::CloseoutStatus::Result.new(
      evidence: build_evidence(evidence),
      blockers: (blockers || []).map { |blocker| build_blocker(blocker) },
      admissible: payload.fetch("admissible", false),
      open_request: nil,
      resolved_current_generation: payload.fetch("resolved_current_generation", false),
      outcome: payload.fetch("outcome"),
      unresolved_prerequisites: payload.fetch("unresolved_prerequisites", []),
      technical_evidence: payload.fetch("technical_evidence", [])
    )
  end

  def build_evidence(evidence)
    Issues::CloseoutEvidence::Result.new(
      merged_prs: evidence.fetch("merged_prs", []).map { |pr| build_merged_pr(pr) },
      no_code_required_at: parse_time(evidence["no_code_required_at"]),
      terminal_at: parse_time(evidence["terminal_at"]),
      digest: evidence["digest"],
      pr_body_revision: evidence["pr_body_revision"]
    )
  end

  def build_merged_pr(pr)
    Issues::CloseoutEvidence::MergedPullRequest.new(
      number: pr["number"],
      url: pr["url"],
      terminal_at: parse_time(pr["terminal_at"]),
      run_id: pr["run_id"],
      body_digest: pr["body_digest"]
    )
  end

  def build_blocker(blocker)
    Issues::CloseoutStatus::Blocker.new(
      code: blocker["code"]&.to_sym,
      message: blocker["message"],
      evidence: blocker["evidence"],
      recovery: blocker["recovery"]
    )
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value)
  end
end
