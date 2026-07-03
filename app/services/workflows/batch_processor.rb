# frozen_string_literal: true

module Workflows
  # Batch processor for agent run status transitions and related updates.
  #
  # Groups multiple agent run operations into batched database queries to
  # reduce per-run overhead. Useful when processing queued runs or updating
  # status for multiple runs simultaneously.
  #
  # @example Batch-update stale runs
  #   Workflows::BatchProcessor.call(
  #     scope: AgentRun.where(status: "running").where("updated_at < ?", 1.hour.ago),
  #     operation: :timeout
  #   )
  class BatchProcessor
    BATCH_SIZE = 50
    OPERATIONS = %i[timeout complete fail requeue].freeze
    TIMEOUT_ERROR_MESSAGE = "Timed out during execution"

    attr_reader :scope, :operation, :batch_size

    def initialize(scope:, operation:, batch_size: BATCH_SIZE)
      @scope = scope
      @operation = operation
      @batch_size = batch_size

      validate!
    end

    def self.call(...)
      new(...).call
    end

    def call
      processed = 0
      errors = []

      scope.find_in_batches(batch_size: batch_size) do |batch|
        result = process_batch(batch)
        processed += result[:updated]
        errors.concat(result[:errors])
      end

      log_summary(processed, errors)
      { processed: processed, errors: errors }
    end

    private

    def validate!
      raise ArgumentError, "Unknown operation: #{operation}" unless OPERATIONS.include?(operation)
    end

    def process_batch(batch)
      case operation
      when :timeout
        batch_timeout(batch)
      when :complete
        batch_complete(batch)
      when :fail
        batch_fail(batch)
      when :requeue
        batch_requeue(batch)
      end
    end

    def batch_timeout(records)
      transition_batch(records) { |agent_run| agent_run.timeout!(error: TIMEOUT_ERROR_MESSAGE) }
    end

    def batch_complete(records)
      transition_batch(records, &:complete!)
    end

    def batch_fail(records)
      transition_batch(records, &:fail!)
    end

    def batch_requeue(records)
      succeeded = 0
      errors = []
      records.each do |agent_run|
        next unless requeue_agent_run(agent_run)
        succeeded += 1
      rescue StandardError => e
        errors << { id: agent_run.id, error: e.message }
      end
      { updated: succeeded, errors: errors }
    end

    def transition_batch(records)
      succeeded = 0
      errors = []
      records.each do |record|
        yield record
        succeeded += 1
      rescue StandardError => e
        errors << { id: record.id, error: e.message }
      end
      { updated: succeeded, errors: errors }
    end

    def requeue_agent_run(agent_run)
      old_resources = {}

      requeued = agent_run.with_lock do
        next false if agent_run.finished?

        old_resources = captured_resources(agent_run)
        unless cancel_temporal_workflow(agent_run, agent_run.temporal_workflow_id)
          raise "Failed to cancel Temporal workflow before requeue"
        end

        agent_run.update!(requeue_attributes(agent_run))
        true
      end

      return false unless requeued

      cleanup_resources(agent_run, old_resources)
      true
    end

    def requeue_attributes(agent_run)
      {
        status: "queued",
        queue_entered_at: Time.current,
        started_at: nil,
        completed_at: nil,
        duration_seconds: nil,
        paused_at: nil,
        guardrail_violation_type: nil,
        guardrail_context: nil,
        error_message: nil,
        stale_requeue_count: agent_run.stale_requeue_count + 1,
        stale_skip_count: 0,
        temporal_workflow_id: nil,
        temporal_run_id: nil,
        service_environment: nil,
        container_id: nil,
        service_container_ids: []
      }
    end

    def captured_resources(agent_run)
      {
        container_id: agent_run.container_id,
        service_container_ids: agent_run.service_container_ids.dup,
        service_environment: agent_run.service_environment&.dup,
        stale_requeue_count: agent_run.stale_requeue_count
      }
    end

    def cancel_temporal_workflow(agent_run, workflow_id)
      return true if workflow_id.blank?
      return true if workflow_id == AgentRun::CLAIMED_SENTINEL

      handle = Paid.temporal_client.workflow_handle(workflow_id)
      handle.cancel
      true
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

      Rails.logger.info(
        message: "workflows.batch_processor.cancel_workflow_not_found",
        agent_run_id: agent_run.id,
        temporal_workflow_id: workflow_id
      )
      true
    rescue => e
      Rails.logger.warn(
        message: "workflows.batch_processor.cancel_workflow_failed",
        agent_run_id: agent_run.id,
        temporal_workflow_id: workflow_id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def cleanup_resources(agent_run, old_resources)
      cleanup_container(agent_run, old_resources[:container_id])
      cleanup_service_containers(agent_run, old_resources)
    end

    def cleanup_container(agent_run, old_container_id)
      return if old_container_id.blank?

      AgentRun.where(id: agent_run.id, container_id: old_container_id).update_all(container_id: nil)

      service = Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: old_container_id,
        worktree_path: agent_run.worktree_path
      )
      service.cleanup(force: true)
    end

    def cleanup_service_containers(agent_run, old_resources)
      service_container_ids = old_resources[:service_container_ids]
      service_environment = old_resources[:service_environment]
      return if service_container_ids.blank?

      agent_run.service_container_ids = service_container_ids
      agent_run.service_environment = service_environment if service_environment.present?
      Containers::ServiceProvisioner.new.cleanup(agent_run,
        stale_requeue_count: old_resources[:stale_requeue_count])
    end

    def log_summary(processed, errors)
      Rails.logger.info(
        message: "workflows.batch_processor.completed",
        component: "agent_execution",
        operation: operation,
        processed_count: processed,
        error_count: errors.size
      )
    end
  end
end
