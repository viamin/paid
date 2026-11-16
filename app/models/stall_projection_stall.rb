# frozen_string_literal: true

# One projected stall of the partial-closeout Inbox lane's persisted read
# model (RDR-081). The row is a display artifact, never an admission
# authority: it snapshots the outcome, the reason automatic continuation
# cannot proceed, the additive structured blockers, and the evidence display
# payload the lane renders, and it is atomically replaced by each successful
# recomputation of its project's checkpoint.
# @spec PARTIAL-CLOSEOUT-042
class StallProjectionStall < ApplicationRecord
  include TenantScoped

  belongs_to :project
  belongs_to :issue

  validates :evidence_digest, :status, :reason, presence: true
  validates :projection_generation, numericality: { greater_than: 0, only_integer: true }
end
