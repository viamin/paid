# frozen_string_literal: true

module AppleVerification
  # Selects an approved image before handing a closed-protocol job to the
  # provider's guest connection. Provider code owns the executor transport;
  # this control-plane boundary owns admission and image selection.
  # @spec APPLE-VERIFY-005
  class ExecuteGuestJob
    Result = Data.define(:image, :operations)

    FeatureDisabledError = Class.new(StandardError)
    NoActiveImageError = Class.new(StandardError)

    def self.call(...)
      new(...).call
    end

    def initialize(project:, manifest:, guest_connection:, image_digest:)
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
