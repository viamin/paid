# frozen_string_literal: true

module AppleVerification
  # Selects an approved image before handing a closed-protocol job to the
  # provider's guest connection. Provider code owns the executor transport;
  # this control-plane boundary owns admission and image selection.
  #
  # This is the dispatch primitive for APPLE-VERIFY-005, not a submission
  # endpoint. Per the RDR-068 issue tree (#3930), the caller that decides a
  # manifest, project, and image digest ("verification work is submitted")
  # is built by later, dependent issues: scheduling/admission (#3936),
  # source/artifact transport (#3937), workflow approval (#3938), and the
  # semantic MCP tools/lifecycle gates (#3940). Wiring a controller or job
  # here now would mean inventing those unbuilt concepts ahead of their
  # issues. This class and its spec cover the dispatch contract in
  # isolation; integration is deferred to #3940.
  # @spec APPLE-VERIFY-005
  class ExecuteGuestJob
    Result = Data.define(:image, :operations)

    FeatureDisabledError = Class.new(StandardError)
    NoActiveImageError = Class.new(StandardError)

    def self.call(...)
      new(...).call
    end

    def initialize(project:, manifest:, guest_connection: GuestConnection.new, image_digest:)
      @project = project
      @manifest = manifest
      @guest_connection = guest_connection
      @image_digest = image_digest
    end

    def call
      ensure_feature_enabled!
      image = active_image!
      GuestProtocol.validate!(@manifest)
      operations = @guest_connection.dispatch!(image:, manifest: @manifest)
      Result.new(image:, operations:)
    end

    private

    def ensure_feature_enabled!
      return if FeatureFlags.enabled?(:apple_verification_workers, project: @project)

      raise FeatureDisabledError, "Apple verification workers are not enabled for this project"
    end

    def active_image!
      AppleVerificationImage.schedulable.find_by(account: @project.account, digest: @image_digest) ||
        raise(NoActiveImageError, "the requested active Apple verification image is unavailable for this account")
    end
  end
end
