# frozen_string_literal: true

module ProjectDelegation
  # Display data for the delegation posture (RDR-080): the decisions that
  # remain human under each level — rendered next to every selection so an
  # owner always sees what stays mandatory before broadening — and the
  # one-line summaries the settings surface shows for each choice.
  #
  # @spec PROJECT-DELEGATION-001
  module PostureDisplay
    REACHABLE_PHASES = {
      Posture::CONSERVATIVE => [],
      Posture::BOUNDED_DELIVERY => [ Automation::Phases::CODING, Automation::Phases::MERGE ]
    }.freeze

    STOP_BOUNDARIES = {
      Posture::CONSERVATIVE => [],
      Posture::BOUNDED_DELIVERY => [ Automation::Phases::MERGE, Automation::Phases::RELEASE_DEPLOYMENT ]
    }.freeze

    REMAINING_REVIEWS = {
      Posture::CONSERVATIVE => [
        { key: "approvals", description: "Every existing approval" },
        { key: "reviews", description: "Pull request reviews" },
        { key: "merges", description: "Merge decisions" },
        { key: "holds", description: "Explicit holds" },
        { key: "unresolved_stops", description: "Unresolved stop decisions" }
      ],
      Posture::BOUNDED_DELIVERY => [
        { key: "material_intent", description: "Settling material product intent" },
        { key: "repository_gates", description: "All existing repository review and merge gates" },
        { key: "routed_exceptions", description: "Every decision routed to a human as an exception" }
      ]
    }.freeze

    SUMMARIES = {
      Posture::CONSERVATIVE => "Current behavior only: Paid surfaces every other downstream decision in the Inbox.",
      Posture::BOUNDED_DELIVERY => "Paid takes bounded technical choices, focused follow-up recording, " \
                                   "technical-stop recovery, evidence-gated closeout, and cycle analysis on its own."
    }.freeze
  end
end
