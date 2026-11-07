# frozen_string_literal: true

# RDR-081 Option B project checkpoint for the persisted partial-closeout stall
# projection. One row per project records the identity of the last successful
# recomputation (`computed_at`, `generation`, `input_watermark`) and bounded
# metadata about the latest failed attempt. A successful checkpoint with zero
# `PartialCloseoutStall` rows means "evaluated with no stalls"; a missing row or
# a null `computed_at` means "not evaluated successfully yet" and the Inbox lane
# stays on the live admission path for that project.
# @spec PARTIAL-CLOSEOUT-042
class PartialCloseoutStallCheckpoint < ApplicationRecord
  belongs_to :project

  # A successful recomputation has committed for this project.
  def evaluated?
    computed_at.present?
  end
end
