# frozen_string_literal: true

module PartialCloseouts
  # Single source string for the Inbox notifications that surface human
  # prerequisites from a partial closeout. The publisher in
  # {Reconcile#publish_operator_prerequisites!} and the eligibility gate in
  # {Automation::Strategies::AutoPick::DefaultCandidateSource#partial_closeout_prerequisite_block_issue_ids}
  # both reference it so the publisher and reader cannot drift apart — a
  # notification the publisher writes under a different string would never
  # be observed by the scheduling block, so the parent issue would be
  # re-picked ahead of the prerequisite (#4119).
  PREREQUISITE_NOTIFICATION_SOURCE = "partial_closeout.prerequisite"

  # Single source string for the non-blocking Inbox notification that records
  # a bounded reassessment requirement when a closeout assessment cannot
  # attribute a human prerequisite to its owning issue
  # ({Reconcile#publish_reassessment_requirement!}). It is deliberately a
  # separate source from PREREQUISITE_NOTIFICATION_SOURCE so the reassessment
  # notice never satisfies — or is cleaned up as — a human-evidence
  # prerequisite occurrence (#4893).
  REASSESSMENT_NOTIFICATION_SOURCE = "partial_closeout.reassessment"
end
