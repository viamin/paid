# frozen_string_literal: true

module AppleVerification
  # Selects an approved image before handing a closed-protocol job to the
  # provider's guest connection. Provider code owns the executor transport;
  # this control-plane boundary owns admission and image selection.
  #
  # This is the guest-admission boundary. It resolves and installs the Paid
  # network contract before the executor receives a manifest, so a guest job
  # cannot start with an implicit or caller-controlled network policy.
  # @spec APPLE-VERIFY-005
  # @spec APPLE-NETWORK-001
  # @spec APPLE-NETWORK-002
  class ExecuteGuestJob
    Result = Data.define(:image, :operations)

    FeatureDisabledError = Class.new(StandardError)
    NoActiveImageError = Class.new(StandardError)

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, manifest:, guest_connection: GuestConnection.new, image_digest:)
      @agent_run = agent_run
      @manifest = manifest
      @guest_connection = guest_connection
      @image_digest = image_digest
    end

    def call
      ensure_feature_enabled!
      image = active_image!
      GuestProtocol.validate!(@manifest)
      contract = resolve_guest_contract
      validate_contract_destinations!(contract)
      operations = @guest_connection.dispatch!(image:, manifest: @manifest, network_contract: contract)
      Result.new(image:, operations:)
    end

    private

    def ensure_feature_enabled!
      return if FeatureFlags.enabled?(:apple_verification_workers, project: project)

      raise FeatureDisabledError, "Apple verification workers are not enabled for this project"
    end

    def active_image!
      AppleVerificationImage.schedulable.find_by(account: project.account, digest: @image_digest) ||
        raise(NoActiveImageError, "the requested active Apple verification image is unavailable for this account")
    end

    def resolve_guest_contract
      AgentRuns::AppleVerification::ResolveGuestContract.call(agent_run: @agent_run)
    end

    def validate_contract_destinations!(contract)
      contract.destinations.select { |destination| external_destination?(destination) }.each do |destination|
        AgentRuns::AppleVerification::ValidateGuestRequest.call(
          agent_run: @agent_run,
          contract: contract,
          request: AgentRuns::AppleVerification::GuestNetworkRequest.new(**destination.merge(scheme: destination[:scheme] || "https"))
        )
      end
    end

    # Paid's proxy and egress-gateway aliases are internal routing hops, not
    # guest-controlled external destinations. HostPattern intentionally
    # rejects their single-label names, so request validation applies only to
    # the external routes the guest may ask the gateway to reach.
    def external_destination?(destination)
      AgentRuns::EgressPolicy::HostPattern.invalid_reason(destination[:host]).nil?
    end

    def project
      @agent_run.project
    end
  end
end
