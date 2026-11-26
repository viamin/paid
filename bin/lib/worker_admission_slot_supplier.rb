# frozen_string_literal: true

require "thread"
require "temporalio/worker/thread_pool"
require "temporalio/worker/tuner"
require_relative "../../lib/paid/worker_admission"

module Paid
  module WorkerAdmission
    RESERVATION_POLL_INTERVAL = 0.05
    WORKFLOW_POLLER_OPTIONS = {
      max_cached_workflows: 1000,
      nonsticky_to_sticky_poll_ratio: 0.2
    }.freeze

    # Keep the SDK dependency on the worker boot path, outside Rails autoload.
    # @spec TEMPORAL-ORCHESTRATION-021
    def self.tuner(workflow_slots:, activity_slots:, local_activity_slots:,
      workflow_task_polls:, activity_task_polls:, readiness_file:)
      workflow_polls = Integer(workflow_task_polls)
      activity_polls = Integer(activity_task_polls)
      raise ArgumentError, "poll counts must be positive" unless workflow_polls.positive? && activity_polls.positive?

      nonsticky = [ (workflow_polls * WORKFLOW_POLLER_OPTIONS.fetch(:nonsticky_to_sticky_poll_ratio)).floor, 1 ].max
      workflow_poll_slots = { false => nonsticky, true => [ workflow_polls - nonsticky, 1 ].max }
      Temporalio::Worker::Tuner.new(
        workflow_slot_supplier: SlotSupplier.new(slots: workflow_slots, poll_slots: workflow_poll_slots, readiness_file:),
        activity_slot_supplier: SlotSupplier.new(slots: activity_slots, poll_slots: { false => activity_polls }, readiness_file:),
        local_activity_slot_supplier: Temporalio::Worker::Tuner::SlotSupplier::Fixed.new(local_activity_slots)
      )
    end

    # A permit owns its shared lock before polling and until SDK release.
    # A separate request must stop reader renewal before an updater can drain.
    # @spec TEMPORAL-ORCHESTRATION-021
    class SlotSupplier < Temporalio::Worker::Tuner::SlotSupplier::Custom
      Permit = Struct.new(:lock, :poll_key)

      def initialize(slots:, readiness_file:, poll_slots: { false => 1, true => 1 })
        @available_slots = Integer(slots)
        raise ArgumentError, "slots must be positive" unless @available_slots.positive?

        @available_polls = poll_slots.transform_values do |count|
          value = Integer(count)
          raise ArgumentError, "poll capacity must be positive" unless value.positive?

          value
        end
        @lock_path = WorkerAdmission.lock_path(readiness_file)
        @request_path = WorkerAdmission.request_path(readiness_file)
        @mutex = Mutex.new
        @available = ConditionVariable.new
      end

      def reserve_slot(context, cancellation)
        poll_key = context.respond_to?(:sticky?) && context.sticky? == true
        until cancellation.canceled?
          permit = acquire_permit(poll_key)
          if permit
            if cancellation.canceled?
              release_permit(permit)
              return
            end

            return yield(permit)
          end

          @mutex.synchronize { @available.wait(@mutex, RESERVATION_POLL_INTERVAL) }
        end
      end

      def try_reserve_slot(_context)
        acquire_permit(nil)
      end

      def mark_slot_used(context)
        @mutex.synchronize do
          return_poll_capacity(context.permit)
          @available.broadcast
        end
        nil
      end

      def release_slot(context)
        release_permit(context.permit)
      end

      private

      def acquire_permit(poll_key)
        return if draining?
        return unless claim_slot(poll_key)

        transferred = false
        begin
          lock = File.open(@lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
          return unless lock.flock(File::LOCK_SH | File::LOCK_NB)
          return if draining?

          transferred = true
          Permit.new(lock, poll_key)
        ensure
          unless transferred
            lock&.close
            return_failed_claim(poll_key)
          end
        end
      rescue SystemCallError
        nil
      end

      def draining?
        File.lstat(@request_path)
        true
      rescue Errno::ENOENT
        false
      rescue SystemCallError
        true
      end

      def claim_slot(poll_key)
        @mutex.synchronize do
          return false if @available_slots.zero?
          return false if !poll_key.nil? && @available_polls.fetch(poll_key, 0).zero?

          @available_slots -= 1
          @available_polls[poll_key] -= 1 unless poll_key.nil?
          true
        end
      end

      def return_failed_claim(poll_key)
        @mutex.synchronize do
          @available_slots += 1
          @available_polls[poll_key] += 1 unless poll_key.nil?
          @available.broadcast
        end
      end

      def release_permit(permit)
        permit.lock.close
        @mutex.synchronize do
          @available_slots += 1
          return_poll_capacity(permit)
          @available.broadcast
        end
      end

      def return_poll_capacity(permit)
        return if permit.poll_key.nil?

        @available_polls[permit.poll_key] += 1
        permit.poll_key = nil
      end
    end
  end
end
