# frozen_string_literal: true

module ExecutionResources
  class Reconcile
    Result = Data.define(:checked, :adopted, :cleaned, :failures, :reduced_confidence)

    def initialize(scope: ExecutionResource.active_or_pending, runner_resolver: nil, inventory_targets: nil)
      @scope = scope
      @runner_resolver = runner_resolver || method(:default_runner_for)
      @inventory_targets = inventory_targets
    end

    def call
      counts = { checked: 0, adopted: 0, cleaned: 0, failures: 0, reduced_confidence: 0 }

      grouped_inventory.each do |(runner_type, host), resources|
        reconcile_group(runner_type:, host:, resources:, counts:)
      end

      Result.new(**counts)
    end

    private

    attr_reader :scope, :runner_resolver

    def grouped_scope
      scope.order(:id).group_by { |resource| [ resource.runner_type, resource.host ] }
    end

    def grouped_inventory
      inventory_targets.each_with_object(grouped_scope) do |target, groups|
        key = [ target.fetch(:runner_type).to_s, target.fetch(:host).to_s ]
        groups[key] ||= []
      end
    end

    def reconcile_group(runner_type:, host:, resources:, counts:)
      runner = runner_resolver.call(runner_type:, host:)

      if runner.supports_resource_listing?
        reconcile_with_listing(resources:, runner:, host:, counts:)
      else
        reconcile_without_listing(resources:, runner:, counts:)
      end
    end

    def reconcile_with_listing(resources:, runner:, host:, counts:)
      listed_index = runner.list_resources(host: host).index_by { |resource| provider_key(resource) }

      resources.each do |resource|
        counts[:checked] += 1
        listed_resource = listed_index.delete(provider_key(resource))
        reconcile_tracked_resource(resource:, listed_resource:, runner:, counts:)
      end

      listed_index.each_value do |listed_resource|
        next unless adoptable?(listed_resource)

        adopted = adopt_resource(listed_resource)
        counts[:adopted] += 1
        cleanup_via_resource(resource: adopted, listed_resource:, runner:, counts:)
      end
    end

    def reconcile_without_listing(resources:, runner:, counts:)
      resources.each do |resource|
        counts[:checked] += 1
        resource.mark_reconciled!(reduced_confidence: true)
        counts[:reduced_confidence] += 1
        next unless resource.cleanup_pending?

        cleanup_via_handle(resource:, runner:, counts:)
      end
    end

    def reconcile_tracked_resource(resource:, listed_resource:, runner:, counts:)
      if listed_resource.nil?
        resource.mark_cleaned!
        counts[:cleaned] += 1
        return
      end

      if resource.cleanup_pending?
        return cleanup_via_handle(resource:, runner:, counts:) if resource.environment? && resource.runner_handle_object

        return cleanup_via_resource(resource:, listed_resource:, runner:, counts:)
      end

      resource.mark_reconciled!
    end

    def cleanup_via_resource(resource:, listed_resource:, runner:, counts:)
      runner.cleanup_resource(resource: listed_resource || resource.to_tracked_resource)
      resource.mark_cleaned!
      counts[:cleaned] += 1
    rescue StandardError => e
      resource.record_cleanup_failure!(error: e)
      counts[:failures] += 1
    end

    def cleanup_via_handle(resource:, runner:, counts:)
      handle = resource.runner_handle_object
      unless handle
        resource.record_cleanup_failure!(error: StandardError.new("runner_handle unavailable for handle-based cleanup"))
        counts[:failures] += 1
        return
      end

      runner.cleanup(handle:, force: true)
      resource.mark_cleaned!
      counts[:cleaned] += 1
    rescue StandardError => e
      resource.record_cleanup_failure!(error: e)
      counts[:failures] += 1
    end

    def adopt_resource(listed_resource)
      tags = listed_resource.tags || {}
      run = AgentRun.find_by(id: tags["paid.agent_run_id"])
      project = run&.project || Project.find_by(id: tags["paid.project_id"])
      resource = ExecutionResource.find_or_initialize_by(
        runner_type: listed_resource.runner_type.to_s,
        host: listed_resource.host.to_s,
        identifier: listed_resource.identifier
      )
      resource.assign_attributes(
        account: run&.project&.account || project&.account,
        project: project,
        agent_run: run,
        resource_type: listed_resource.resource_type.to_s,
        tags: tags,
        workspace_ref: listed_resource.workspace_ref,
        metadata: listed_resource.metadata || {},
        state: "cleanup_pending",
        adopted_at: resource.adopted_at || Time.current,
        next_cleanup_at: Time.current,
        reduced_confidence: false
      )
      resource.save!
      resource
    end

    def adoptable?(listed_resource)
      tags = listed_resource.tags || {}
      return false if tags["paid.service_container"] == "true"
      return false if tags["paid.container_pool"] == "true"

      listed_resource.resource_type == "environment" ||
        (listed_resource.resource_type == "workspace" && tags["paid.resource"] == "workspace_volume")
    end

    def provider_key(resource)
      [
        resource.resource_type.to_s,
        resource.identifier.to_s,
        resource.host.to_s
      ]
    end

    def default_runner_for(runner_type:, host:)
      case runner_type.to_s
      when "local_docker", ""
        ExecutionRunners::LocalDockerRunner.new
      else
        ExecutionRunners.resolve(backend: Containers.backend_for(host))
      end
    end

    def inventory_targets
      @inventory_targets || default_inventory_targets
    end

    def default_inventory_targets
      Containers.all_backends.map do |backend|
        { runner_type: "local_docker", host: backend.identifier.to_s }
      end
    rescue StandardError
      [ { runner_type: "local_docker", host: "local" } ]
    end
  end
end
