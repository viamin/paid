# frozen_string_literal: true

# One persisted stalled-issue row of the display-only partial-closeout stall
# projection (RDR-081). The row records why the issue was stalled when the
# checkpoint's generation was computed — the serialized `CloseoutStatus`
# display payload plus its additive structured blockers — never admission
# authority: `Issues::RequestContinuation` preflights and the dequeue recheck
# still decide live against `DefaultCandidateSource.eligible_scope`.
# @spec PARTIAL-CLOSEOUT-042
class PartialCloseoutStall < ApplicationRecord
  belongs_to :account
  belongs_to :project
  belongs_to :issue

  validates :evidence_digest, presence: true
  validates :projection_generation, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
end
