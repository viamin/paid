# frozen_string_literal: true

module AppleVerification
  # Reconciliation-only runner for Apple VMs. It deliberately exposes only
  # provider-neutral inventory and cleanup operations to the control plane.
  # @spec APPLE-WORKER-003
  class TartRunner < ExecutionRunners::Base
    RUNNER_TYPE = :apple_tart
    RESOURCE_KIND = "apple_vm"

    def self.register_from_environment!
      runner = from_environment
      return ExecutionRunners.unregister_reconciliation_runner(RUNNER_TYPE) unless runner

      ExecutionRunners.register_reconciliation_runner(runner)
    end

    def self.from_environment
      endpoint = ENV["APPLE_VERIFICATION_HOST_URL"]
      token = ENV["APPLE_VERIFICATION_HOST_TOKEN"]
      return if endpoint.blank? || token.blank?

      new(host: HostClient.new(endpoint:), token:)
    end

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

      host.call(version: HostService::API_VERSION, operation: "inventory", payload: { "ownership_tags" => tags }, token:).map do |resource|
        ExecutionRunners::ManagedResource.new(
          runner_type: RUNNER_TYPE, resource_kind: RESOURCE_KIND, identifier: resource.fetch("vm_id"), host: nil,
          ownership_tags: resource.fetch("tags", {}), metadata: resource.slice("state", "image_id")
        )
      end
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
