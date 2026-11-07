# frozen_string_literal: true

module TrustedMeasurements
  # The identity of the revision Paid believes is currently deployed and
  # serving the live data a trusted measurement reads. Sourced from the
  # deploy pipeline's environment variable rather than inferred from any
  # repository checkout, so a measurement can be bound to "what is actually
  # running" without granting it any code-execution capability.
  #
  # A missing signal is not an error on its own: it is recorded on the
  # attempt as an unknown revision, which keeps the resulting evidence from
  # ever being treated as current (see
  # TrustedMeasurementAttempt#current_for_revision?).
  module DeploymentSignal
    ENV_KEY = "PAID_DEPLOYED_REVISION"

    def self.current
      ENV[ENV_KEY].presence
    end
  end
end
