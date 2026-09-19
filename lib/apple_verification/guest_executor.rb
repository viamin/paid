# frozen_string_literal: true

module AppleVerification
  # Dispatches validated operations to image-owned adapters. Adapter lookup is
  # keyed by the fixed vocabulary, so a manifest cannot select an executable
  # or inject a command into the guest.
  # @spec APPLE-VERIFY-003
  class GuestExecutor
    def initialize(adapters)
      @adapters = adapters.stringify_keys
    end

    def execute!(manifest)
      GuestProtocol.validate!(manifest)
      manifest.fetch("operations").map { |operation| execute(operation) }
    end

    private

    attr_reader :adapters

    def execute(operation)
      adapter_for(operation.fetch("type")).call(operation.fetch("payload"))
    end

    def adapter_for(type)
      adapters.fetch(type) { raise GuestProtocol::UnsupportedOperationError, "guest image does not support #{type}" }
    end
  end
end
