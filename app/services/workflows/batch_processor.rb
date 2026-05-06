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
      ids = batch.map(&:id)
      updated = 0
      errors = []

      case operation
      when :timeout
        updated = batch_timeout(ids)
      when :complete
        updated = batch_complete(ids)
      when :fail
        updated = batch_fail(ids)
      when :requeue
        updated = batch_requeue(ids)
      end

      { updated: updated, errors: errors }
    rescue StandardError => e
      { updated: 0, errors: [ { batch_ids: ids, error: e.message } ] }
    end

    def batch_timeout(ids)
      AgentRun.where(id: ids).update_all(
        status: "failed",
        error_message: "Timed out during execution",
        completed_at: Time.current,
        updated_at: Time.current
      )
    end

    def batch_complete(ids)
      AgentRun.where(id: ids).update_all(
        status: "completed",
        completed_at: Time.current,
        updated_at: Time.current
      )
    end

    def batch_fail(ids)
      AgentRun.where(id: ids).update_all(
        status: "failed",
        completed_at: Time.current,
        updated_at: Time.current
      )
    end

    def batch_requeue(ids)
      AgentRun.where(id: ids).update_all(
        status: "queued",
        started_at: nil,
        error_message: nil,
        stale_requeue_count: Arel.sql("stale_requeue_count + 1"),
        updated_at: Time.current
      )
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
