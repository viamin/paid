# frozen_string_literal: true

module LayeredVerification
  # Captures the current execution inputs used to admit and stamp audit work.
  # @spec LAYERED-VERIFY-019
  class DependencySnapshot
    class UnknownProducerVersionError < ArgumentError; end

    def self.call(project:, paid_revision: Paid::WorkerReadiness.boot_revision)
      runtime = Containers::RuntimeImageSelector.select(project:).metadata
      paid_revision = paid_revision.presence ||
        raise(UnknownProducerVersionError, "Paid revision could not be established")
      { "environment" => runtime, "policy" => "layered-verification-v1",
        "producer_versions" => { "paid" => paid_revision },
        "tool_versions" => { "tlc_runtime_image_digest" => runtime["digest"] } }
    end
  end
end
