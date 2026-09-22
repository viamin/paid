# frozen_string_literal: true

module AppleVerification
  # Control-plane lifecycle that records the crash-window intent before clone
  # and stores only the opaque VM handle after successful start.
  # @spec APPLE-WORKER-007
  # @spec APPLE-WORKER-010
  class Lifecycle
    RUNNER_TYPE = "apple_tart"
    RESOURCE_KIND = "apple_vm"
    # The status set the {#destroy} path accepts as a real live VM to call
    # host.destroy on; anything outside this set has already been recorded as
    # gone by reconciliation and a destroy call would either fail or be a
    # no-op against the host. The ledger entry's status transitions are
    # governed by {ExecutionResourceLedgerEntry::ALLOWED_STATUS_TRANSITIONS}.
    LIVE_VM_STATUSES = %w[provisioning active cleanup_pending orphaned cleanup_failed].freeze

    def initialize(host:, token:, environment: Rails.env)
      @host = host
      @token = token
      @environment = environment
    end

    # Builds a lifecycle from the +APPLE_VERIFICATION_HOST_URL+ and
    # +APPLE_VERIFICATION_HOST_TOKEN+ environment variables, matching the
    # {AppleVerification::TartRunner.from_environment} discovery path. Returns
    # nil when the host service is not configured (so the retention sweep can
    # fall back to a no-op instead of crashing the job in environments where
    # the sweep runs before the macOS worker has been deployed).
    def self.from_environment
      endpoint = ENV["APPLE_VERIFICATION_HOST_URL"]
      token = ENV["APPLE_VERIFICATION_HOST_TOKEN"]
      return nil if endpoint.blank? || token.blank?

      new(host: HostClient.new(endpoint:), token:)
    end

    def provision(agent_run:, image_id:, profile_id:, request_id:, apple_verification_attempt: nil)
      require_enabled!(agent_run.project)
      require_request_id!(request_id)
      ledger = provisioning_ledger
      intent = find_or_record_intent(ledger:, agent_run:, request_id:)
      return ExecutionRunners::RunnerHandle.from_json(intent.runner_handle) if intent.linked?

      tags = ownership_tags_for(intent)
      entry = resource_entry_for(agent_run:, tags:, apple_verification_attempt:)
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

    # Drives the real host-side destroy for an attempt's verification VM and
    # confirms the ledger entry as deleted. The caller (e.g.
    # {AppleVerification::Bundles::RetentionSweep}) is responsible for setting
    # +container_retained_until+ before invoking this method so the audit
    # event recorded downstream by {AppleVerification::Revocation::Enforce}
    # reflects a real destroy rather than a no-op. The method is idempotent:
    # if the attempt has no live ledger entry or no recorded +vm_id+ it
    # returns +:noop+ without raising, which lets the sweep continue across
    # attempts whose VM was never provisioned (or was already destroyed by an
    # earlier sweep run).
    def destroy(attempt:, request_id:)
      require_enabled!(attempt.project)
      require_request_id!(request_id)

      entry = resource_entry_for_attempt(attempt)
      return :noop unless entry
      return :noop if entry.provider_resource_id.blank?

      vm_id = entry.provider_resource_id
      request("destroy", "request_id" => request_id, "vm_id" => vm_id)
      entry.request_cleanup!
      entry.mark_deleted!
      :destroyed
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

    def resource_entry_for(agent_run:, tags:, apple_verification_attempt: nil)
      attrs = {
        account: agent_run.project.account, project: agent_run.project, agent_run:, runner_type: RUNNER_TYPE,
        backend: TartProvider::PROVIDER_NAME, resource_kind: "verification_vm", tags:,
        runner_handle: {}, status: "provisioning"
      }
      attrs[:apple_verification_attempt] = apple_verification_attempt if apple_verification_attempt
      ExecutionResourceLedgerEntry.find_or_create_by!(agent_run:, runner_type: RUNNER_TYPE, tags:) do |row|
        row.assign_attributes(attrs)
      end
    end

    def resource_entry_for_attempt(attempt)
      ExecutionResourceLedgerEntry
        .where(apple_verification_attempt_id: attempt.id, runner_type: RUNNER_TYPE, resource_kind: "verification_vm")
        .where(status: LIVE_VM_STATUSES)
        .first
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
