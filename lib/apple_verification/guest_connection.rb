# frozen_string_literal: true

module AppleVerification
  # Provider-owned implementations send validated jobs to an authenticated
  # executor inside the selected guest. They must not execute project work on
  # the control plane or virtualization host.
  # @spec APPLE-VERIFY-005
  class GuestConnection
    def dispatch!(image:, manifest:)
      raise NotImplementedError, "Apple verification guest connections must dispatch to a guest executor"
    end
  end
end
