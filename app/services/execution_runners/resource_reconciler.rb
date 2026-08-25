# frozen_string_literal: true

module ExecutionRunners
  # Periodically discovers crash-window and tag-discovered orphan resources and
  # drains the durable cleanup queue with backoff.
  #
  # @spec CONTAINER-RUNTIME-035
  # @spec CONTAINER-RUNTIME-036
  class ResourceReconciler
    RETRY_DELAYS = [
      5.minutes,
      15.minutes,
      30.minutes,
      1.hour
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(runners: ExecutionRunners.reconciliation_runners, logger: Rails.logger)
      @runners = runners
      @logger = logger
    end

    def call
      enqueued = enqueue_orphan_intents
      enqueued += enqueue_tag_discovered_orphans
      cleaned, failed = drain_cleanup_queue

      {
        enqueued: enqueued,
        cleaned: cleaned,
        failed: failed
      }
    end

    private

    attr_reader :runners, :logger

    def enqueue_orphan_intents
      ProvisioningIntent.orphans.find_each.sum do |intent|
        enqueue_cleanup(resource_from_intent(intent), provisioning_intent: intent)
      end
    end

    def enqueue_tag_discovered_orphans
      runners.sum do |runner|
        next 0 unless runner.supports_tag_reconciliation?

        resources = runner.list_resources_by_tags(
          tags: required_discovery_tags,
          resource_kind: runner.resource_kind
        )
        orphaned_resources_for(resources).sum do |resource|
          enqueue_cleanup(resource)
        end
      end
    end

    def required_discovery_tags
      ExecutionRunners::REQUIRED_RECONCILIATION_TAG_NAMES.to_h do |tag_name|
        [ "paid.#{tag_name}", nil ]
      end
    end

    def orphaned_resources_for(resources)
      run_ids = resources.filter_map do |resource|
        resource.ownership_tags["paid.run_id"] || resource.ownership_tags["paid.run"]
      end
      active_run_ids = AgentRun.capacity_inflight.where(id: run_ids).pluck(:id).map(&:to_s).to_set

      resources.select do |resource|
        run_id = resource.ownership_tags["paid.run_id"] || resource.ownership_tags["paid.run"]
        run_id.present? && !active_run_ids.include?(run_id.to_s)
      end
    end

    def enqueue_cleanup(resource, provisioning_intent: nil)
      return 0 if resource.identifier.blank?

      request = ExecutionResourceCleanup.find_or_initialize_by(
        runner_type: resource.runner_type.to_s,
        resource_kind: resource.resource_kind.to_s,
        provider_resource_id: resource.identifier,
        provider_resource_host: resource.host.to_s
      )
      return 0 if request.completed?

      request.assign_attributes(
        account_id: provisioning_intent&.account_id || id_from_tag(resource, "account_id"),
        project_id: provisioning_intent&.project_id || id_from_tag(resource, "project_id"),
        agent_run_id: provisioning_intent&.agent_run_id || id_from_tag(resource, "run_id"),
        provisioning_intent: provisioning_intent || request.provisioning_intent,
        ownership_tags: resource.ownership_tags,
        next_attempt_at: request.next_attempt_at || Time.current,
        status: ExecutionResourceCleanup::STATUS_PENDING
      )
      request.save! if request.changed?
      1
    end

    def drain_cleanup_queue
      cleaned = 0
      failed = 0

      ExecutionResourceCleanup.due.find_each do |request|
        cleanup_request(request)
        cleaned += 1
      rescue StandardError => e
        failed += 1
        request.record_failure!(error: e.message, next_attempt_at: next_retry_at(request))
        logger.warn(
          message: "execution_resources.cleanup_retry_scheduled",
          execution_resource_cleanup_id: request.id,
          runner_type: request.runner_type,
          provider_resource_id: request.provider_resource_id,
          attempts: request.attempts,
          error_class: e.class.name,
          error: e.message
        )
      end

      [ cleaned, failed ]
    end

    def cleanup_request(request)
      runner = ExecutionRunners.for_type(request.runner_type)
      runner.cleanup_resource(resource: resource_from_request(request), force: true)
      request.mark_completed!
      request.provisioning_intent&.mark_reconciled_cleanup!(cleanup_id: request.id)
    end

    def resource_from_request(request)
      ExecutionRunners::ManagedResource.new(
        runner_type: request.runner_type,
        resource_kind: request.resource_kind,
        identifier: request.provider_resource_id,
        host: request.provider_resource_host.presence,
        ownership_tags: request.ownership_tags,
        metadata: {}
      )
    end

    def resource_from_intent(intent)
      ExecutionRunners::ManagedResource.new(
        runner_type: intent.runner_type,
        resource_kind: intent.resource_kind,
        identifier: intent.provider_resource_id,
        host: intent.provider_resource_host,
        ownership_tags: intent.ownership_tags,
        metadata: {}
      )
    end

    def next_retry_at(request)
      delay = RETRY_DELAYS.fetch([ request.attempts, RETRY_DELAYS.length - 1 ].min)
      Time.current + delay
    end

    def id_from_tag(resource, tag_name)
      value = resource.ownership_tags["paid.#{tag_name}"]
      return if value.blank? || !value.to_s.match?(/\A\d+\z/)

      value.to_i
    end
  end
end
