# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Injected production surfaces. The CLI wires these from the shipped
    # control-plane objects; specs wire fakes. Missing optional ports
    # degrade their scenarios to recorded gaps.
    # @spec APPLE-LIVE-002
    Ports = Struct.new(:lifecycle, :dispatcher, :diagnostics, :capacity_sampler, :reconciler, :timeout_policy,
      :run_factory, keyword_init: true)
  end
end
