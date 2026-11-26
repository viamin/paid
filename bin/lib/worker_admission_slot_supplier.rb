# frozen_string_literal: true

require "thread"
require "temporalio/worker/thread_pool"
require "temporalio/worker/tuner"
require_relative "../../lib/paid/worker_admission"

module Paid
  module WorkerAdmission
    RESERVATION_POLL_INTERVAL = 0.05

    # Keep the SDK dependency on the worker boot path, outside Rails autoload.
    # @spec TEMPORAL-ORCHESTRATION-021
    def self.tuner(workflow_slots:, activity_slots:, local_activity_slots:, readiness_file:)
      Temporalio::Worker::Tuner.new(
        workflow_slot_supplier: SlotSupplier.new(slots: workflow_slots, readiness_file:),
        activity_slot_supplier: SlotSupplier.new(slots: activity_slots, readiness_file:),
        local_activity_slot_supplier: Temporalio::Worker::Tuner::SlotSupplier::Fixed.new(local_activity_slots)
      )
    end

    # A permit owns its shared lock before polling and until SDK release.
    # A separate request must stop reader renewal before an updater can drain.
    # @spec TEMPORAL-ORCHESTRATION-021
    class SlotSupplier < Temporalio::Worker::Tuner::SlotSupplier::Custom
      Permit = Struct.new(:lock)

      def initialize(slots:, readiness_file:)
        @available_slots = Integer(slots)
        raise ArgumentError, "slots must be positive" unless @available_slots.positive?

        @lock_path = WorkerAdmission.lock_path(readiness_file)
        @request_path = WorkerAdmission.request_path(readiness_file)
        @mutex = Mutex.new
        @available = ConditionVariable.new
      end

      def reserve_slot(_context, cancellation)
        until cancellation.canceled?
          permit = acquire_permit
          if permit
            if cancellation.canceled?
              permit.lock.close
              return_slot
              return
            end

            return yield(permit)
          end

          @mutex.synchronize { @available.wait(@mutex, RESERVATION_POLL_INTERVAL) }
        end
      end

      def try_reserve_slot(_context)
        acquire_permit
      end

      def mark_slot_used(_context); end

      def release_slot(context)
        context.permit.lock.close
        return_slot
      end

      private

      def acquire_permit
        return if draining?
        return unless claim_slot

        transferred = false
        begin
          lock = File.open(@lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
          return unless lock.flock(File::LOCK_SH | File::LOCK_NB)
          return if draining?

          transferred = true
          Permit.new(lock)
        ensure
          unless transferred
            lock&.close
            return_slot
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

      def claim_slot
        @mutex.synchronize do
          return false if @available_slots.zero?

          @available_slots -= 1
          true
        end
      end

      def return_slot
        @mutex.synchronize do
          @available_slots += 1
          @available.signal
        end
      end
    end
  end
end
