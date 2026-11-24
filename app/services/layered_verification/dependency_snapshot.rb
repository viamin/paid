# frozen_string_literal: true

module LayeredVerification
  # Captures the current execution inputs used to admit and stamp audit work.
  # @spec LAYERED-VERIFY-019
  class DependencySnapshot
    def self.call(project:)
      runtime = Containers::RuntimeImageSelector.select(project:).metadata
      { "environment" => runtime, "policy" => "layered-verification-v1",
        "producer_versions" => { "paid" => ENV.fetch("APP_VERSION", "unversioned") },
        "tool_versions" => { "tlc_runtime_image_digest" => runtime["digest"] } }
    end
  end
end
