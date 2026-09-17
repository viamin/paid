# frozen_string_literal: true

# A design pull request (RDR and/or LID Planning) linked to a feature intent.
# Tracks the head SHA Paid last synced so approval readiness can detect a
# stale head — a commit landing on the PR after a human's Mark approved
# invalidates that approval until the new head is reviewed (RDR-066
# "Approval sources and revision binding").
# @spec FEATURE-APPROVAL-003
class FeatureIntentDesignPr < ApplicationRecord
  KINDS = %w[rdr lid_planning].freeze

  belongs_to :feature_intent

  validates :pull_request_number, presence: true,
    uniqueness: { scope: :feature_intent_id }
  validates :design_pr_kind, presence: true, inclusion: { in: KINDS }
  validates :head_sha, presence: true

  def merged? = merged_at.present?

  def github_url = "#{feature_intent.project.github_url}/pull/#{pull_request_number}"

  # A commit landed after the open decisions/evidence were generated for
  # this PR (or after a prior approval reviewed it). Paid must re-evaluate
  # the new head before a human can decide — approving without doing so
  # would let an unreviewed change ride in on the old readiness signal.
  def stale?
    reviewed_head_sha.present? && reviewed_head_sha != head_sha
  end
end
