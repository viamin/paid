# frozen_string_literal: true

# Namespace for the RDR-067 design-amendment flow services.
module DesignAmendments
  # Raised when the amendment flow is requested while the
  # `approved_intent_amendments` feature flag (RDR-067 rollout guard) is off.
  class DisabledError < StandardError; end

  # Raised when completing an amendment whose human approval is missing or
  # not current for the merged revision.
  class NotApprovedError < StandardError; end

  # Raised when a lifecycle move is requested from a status that does not
  # allow it.
  class InvalidTransitionError < StandardError; end
end
