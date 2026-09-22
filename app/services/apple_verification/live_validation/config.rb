# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # One harness run's configuration: the injected ports, the validation
    # agent run, the approved image/profile to clone, and the repeat count
    # for the clean-clone acceptance scenarios.
    # @spec APPLE-LIVE-002
    Config = Data.define(:ports, :agent_run, :image_id, :profile_id, :repeats, :run_key, :environment, :source_digest,
      :suite, :network_probes) do
      def initialize(ports:, agent_run:, image_id:, profile_id:, repeats: 1, run_key: SecureRandom.hex(4),
        environment: {}, source_digest: "0" * 64, suite: Suite, network_probes: NetworkProbes)
        super
      end
    end
  end
end
