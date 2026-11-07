# frozen_string_literal: true

module PostDeployMeasurements
  # Single source string for the non-blocking escalation notification that
  # surfaces a post-deploy measurement a trusted path cannot currently
  # collect (missing capability/check, persistent failure, contradictory
  # result). Deliberately not blocking: the measurement request is
  # machine-owned, so escalation must not fabricate a human evidence task
  # (#4893 precedent).
  ESCALATION_NOTIFICATION_SOURCE = "post_deploy_measurement.escalation"
end
