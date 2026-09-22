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

    # The contract is built from the resolved egress snapshot, which already
    # rejects unsafe allowlist entries and bad hosts at resolution time. This
    # check is a second-line invariant: if a regression or a future code path
    # lets an invalid destination reach the contract, abort dispatch with the
    # same +network_policy+ error category so the audit trail records a single
    # boundary failure rather than letting the guest receive a contract we
    # could not enforce. A direct IP entry would route around every gateway
    # rule (the gateway cannot resolve a literal), and a non-HTTP(S) scheme
    # is not a shape {ValidateGuestRequest} accepts at request time.
    def validate_contract_destinations!(contract)
      contract.destinations.each do |destination|
        reject_ip_literal_destination!(destination)
        reject_invalid_scheme_destination!(destination)
      end
    end

    def reject_ip_literal_destination!(destination)
      return unless AgentRuns::EgressPolicy::HostPattern.ip_literal?(destination[:host].to_s)

      raise AgentRuns::AppleVerification::NetworkPolicyError, "apple guest contract destination must not be an IP literal"
    end

    def reject_invalid_scheme_destination!(destination)
      scheme = destination[:scheme]
      return if scheme.nil? || AgentRuns::AppleVerification::GuestContract::SCHEMES.include?(scheme)

      raise AgentRuns::AppleVerification::NetworkPolicyError, "apple guest contract destination has invalid scheme: #{scheme.inspect}"
    end

    def project
      @agent_run.project
    end
  end
end
