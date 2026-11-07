# frozen_string_literal: true

# One projected partial-closeout stall, owned by its project checkpoint
# (RDR-081). The row is a display-only read model: `status` and `blockers`
# rehydrate the `Issues::CloseoutStatus::Result` the Inbox renders, so list,
# badge, and filter surfaces never re-evaluate live admission. It never grants
# a continuation and never mutates `paid_state`.
# @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
class PartialCloseoutStall < ApplicationRecord
  belongs_to :project
  belongs_to :issue

  validates :evidence_digest, presence: true
  validates :projection_generation, numericality: { only_integer: true, greater_than: 0 }
end
