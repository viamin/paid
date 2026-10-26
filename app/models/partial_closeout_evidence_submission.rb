# frozen_string_literal: true

# Immutable operator-provided evidence for one partial-closeout prerequisite.
# A submission is not an attestation: only a later sufficient disposition may
# resolve its exact notification prerequisite.
class PartialCloseoutEvidenceSubmission < ApplicationRecord
  OUTCOMES = %w[submitted pending_validation sufficient insufficient stale unavailable].freeze
  EVIDENCE_KINDS = %w[shadow_evaluation_report agent_run durable_artifact link].freeze

  belongs_to :issue
  belongs_to :notification
  belongs_to :actor, class_name: "User"

  validates :criterion, :prerequisite_identity, :source_revision, :intent_revision, :reason, :explanation, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :evidence_kind, inclusion: { in: EVIDENCE_KINDS }
  validates :source_url, format: { with: %r{\Ahttps?://} }, allow_blank: true
end
