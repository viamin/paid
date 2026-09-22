# frozen_string_literal: true

module AppleVerification
  # Control-plane lifecycle that records the crash-window intent before clone
  # and stores only the opaque VM handle after successful start.
  # @spec APPLE-WORKER-007
  # @spec APPLE-WORKER-010
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
      require_request_id!(request_id)
      ledger = provisioning_ledger
      intent = find_or_record_intent(ledger:, agent_run:, request_id:)
      return ExecutionRunners::RunnerHandle.from_json(intent.runner_handle) if intent.linked?

      tags = ownership_tags_for(intent)
      entry = resource_entry_for(agent_run:, tags:)
      vm_id = intent.provider_resource_id || clone_vm(ledger:, intent:, entry:, payload: clone_payload(request_id:, image_id:, tags:))
      started = request("start", "request_id" => "#{request_id}:start", "vm_id" => vm_id, "profile_id" => profile_id)
      handle = handle_for(vm_id:, response: started)
      ledger.link_handle(intent, handle)
      entry.activate!(provider_resource_id: handle.identifier, runner_handle: handle.to_storage)
      handle
    rescue StandardError
      ledger&.mark_failed(intent) if intent&.pending?
      raise
    end

    private

    attr_reader :host, :token, :environment

    def require_enabled!(project)
      return if FeatureFlags.enabled?(:apple_verification_workers, project:)

      raise HostService::UnsupportedRequestError, "Apple verification workers are disabled for this project"
    end

    def require_request_id!(request_id)
      raise ArgumentError, "Apple lifecycle request ID is required" if request_id.to_s.blank?
    end

    def provisioning_ledger
      ExecutionRunners::ProvisioningLedger.new(
        runner_type: RUNNER_TYPE, resource_kind: RESOURCE_KIND, environment:, supports_tagging: true, supports_listing: true
      )
    end

    def find_or_record_intent(ledger:, agent_run:, request_id:)
      agent_run.with_lock do
        intent_for(agent_run:, request_id:) || record_intent(ledger:, agent_run:, request_id:)
      end
    end

    def record_intent(ledger:, agent_run:, request_id:)
      attempt = ledger.next_attempt_for(agent_run:)
      ledger.record_intent(agent_run:, attempt:, request_id:, metadata: { "request_id" => request_id })
    end

    def intent_for(agent_run:, request_id:)
      ProvisioningIntent.find_by(agent_run:, runner_type: RUNNER_TYPE, request_id:)
    end

    def resource_entry_for(agent_run:, tags:)
      ExecutionResourceLedgerEntry.find_or_create_by!(agent_run:, runner_type: RUNNER_TYPE, tags:) do |entry|
        entry.assign_attributes(
          account: agent_run.project.account, project: agent_run.project, agent_run:, runner_type: RUNNER_TYPE,
          backend: TartProvider::PROVIDER_NAME, resource_kind: "verification_vm", tags:, runner_handle: {}, status: "provisioning"
        )
      end
    end

    def ownership_tags_for(intent)
      tags = intent.ownership_tags.merge(TartProvider::REQUEST_ID_TAG => intent.request_id)
      return tags if intent.ownership_tags == tags

      intent.update!(ownership_tags: tags)
      tags
    end

    def clone_vm(ledger:, intent:, entry:, payload:)
      clone = request("clone", payload)
      vm_id = clone.fetch("vm_id")
      ledger.link_created(intent, provider_resource_id: vm_id, host: nil)
      entry.update!(provider_resource_id: vm_id)
      vm_id
    end

    def clone_payload(request_id:, image_id:, tags:)
      { "request_id" => request_id, "image_id" => image_id, "ownership_tags" => tags }
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
