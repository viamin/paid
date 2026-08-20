# frozen_string_literal: true

# Bounds the label-event replay used by escalation-dismissal detection to the
# current escalation cycle. Without a boundary, an `unlabeled` event from a
# previous escalation (which the owner already dismissed) can satisfy the
# "trusted user removed the label" check on a subsequent re-escalation whose
# own label write failed — granting a full counter reset (and, for token-cap
# escalations, the permanent waiver) with no owner action this cycle.
#
# @spec PR-ESCALATION-019
class AddPrEscalationStartedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pr_escalation_started_at, :datetime,
      comment: "Timestamp when this PR entered the escalated phase. Bounds " \
               "the paid-escalated label-event replay so an unlabeled event " \
               "from a prior escalation cycle cannot read as a fresh owner " \
               "dismissal."
  end
end
