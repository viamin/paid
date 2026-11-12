# frozen_string_literal: true

# Append-only audit trail of explicit human customize/replace decisions on a
# work item's assignment, preserved so mapping changes never silently
# overwrite a recorded human decision.
#
# @spec UNIFIED-WORK-ITEMS-004
class WorkItemAssignmentOverride < ApplicationRecord
  MODES = %w[customized replaced].freeze

  belongs_to :account
  belongs_to :work_item
  belongs_to :actor, class_name: "User", optional: true

  validates :mode, presence: true, inclusion: { in: MODES }
end
