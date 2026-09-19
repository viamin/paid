# frozen_string_literal: true

module AppleVerification
  # Control-plane lifecycle that records the crash-window intent before clone
  # and stores only the opaque VM handle after successful start.
  # @spec APPLE-WORKER-003
  class Lifecycle
    RUNNER_TYPE = "apple_tart"
    RESOURCE_KIND = "apple_vm"

    def initialize(host:, token:, environment: Rails.env)
      @host = host
      @token = token
      @environment = environment
    end

    def provision(agent_run:, image_id:, profile_id:, request_id:)
      require_enabled!(agent_run.project)
      ledger = provisioning_ledger
      attempt = ledger.next_attempt_for(agent_run:)
      intent = ledger.record_intent(agent_run:, attempt:)
      tags = ledger.ownership_labels_for(agent_run:, attempt:)
      entry = create_resource_entry(agent_run:, tags:)
      clone = request("clone", "request_id" => request_id, "image_id" => image_id, "ownership_tags" => tags)
      ledger.link_created(intent, provider_resource_id: clone.fetch("vm_id"), host: nil)
      started = request("start", "request_id" => "#{request_id}:start", "vm_id" => clone.fetch("vm_id"), "profile_id" => profile_id)
      handle = handle_for(vm_id: clone.fetch("vm_id"), response: started)
      ledger.link_handle(intent, handle)
      entry.activate!(provider_resource_id: handle.identifier, runner_handle: handle.to_storage)
      handle
    rescue StandardError
      ledger&.mark_failed(intent)
      raise
    end

    private

    attr_reader :host, :token, :environment

    def require_enabled!(project)
      return if FeatureFlags.enabled?(:apple_verification_workers, project:)

      raise HostService::UnsupportedRequestError, "Apple verification workers are disabled for this project"
    end

    def provisioning_ledger
      ExecutionRunners::ProvisioningLedger.new(
        runner_type: RUNNER_TYPE, resource_kind: RESOURCE_KIND, environment:, supports_tagging: true, supports_listing: true
      )
    end

    def create_resource_entry(agent_run:, tags:)
      ExecutionResourceLedgerEntry.create!(
        account: agent_run.project.account, project: agent_run.project, agent_run:, runner_type: RUNNER_TYPE,
        backend: TartProvider::PROVIDER_NAME, resource_kind: "primary_environment", tags:, runner_handle: {}, status: "provisioning"
      )
    end

    def request(operation, payload)
      host.call(version: HostService::API_VERSION, operation:, payload:, token:)
    end

    def handle_for(vm_id:, response:)
      ExecutionRunners::RunnerHandle.new(
        runner_type: :apple_tart, identifier: vm_id, host: nil, workspace_ref: nil,
        metadata: { "provider" => TartProvider::PROVIDER_NAME, "guest_connection" => response["connection"] || {} }
      )
    end
  end
end
