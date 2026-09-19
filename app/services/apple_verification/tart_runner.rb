# frozen_string_literal: true

module AppleVerification
  # Reconciliation-only runner for Apple VMs. It deliberately exposes only
  # provider-neutral inventory and cleanup operations to the control plane.
  # @spec APPLE-WORKER-003
  class TartRunner < ExecutionRunners::Base
    RUNNER_TYPE = :apple_tart
    RESOURCE_KIND = "apple_vm"

    def initialize(host:, token:)
      @host = host
      @token = token
    end

    def runner_type = RUNNER_TYPE
    def resource_kind = RESOURCE_KIND
    def supports_tagging? = true
    def supports_listing? = true
    def supports_tag_reconciliation? = true

    def list_resources_by_tags(tags:, resource_kind: nil)
      return [] if resource_kind.present? && resource_kind != RESOURCE_KIND

      host.call(version: HostService::API_VERSION, operation: "inventory", payload: { "ownership_tags" => tags }, token:)
    end

    def cleanup_resource(resource:, force: false)
      host.call(
        version: HostService::API_VERSION,
        operation: "destroy",
        payload: { "request_id" => "reconcile:#{resource.identifier}", "vm_id" => resource.identifier },
        token:
      )
    end

    private

    attr_reader :host, :token
  end
end
