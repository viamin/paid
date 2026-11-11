# frozen_string_literal: true

module WorkItems
  module Lifecycle
    # Applies a lifecycle change observed from the provider (Linear). Loop
    # prevention: an unchanged native state is a no-op. Conflict review: if
    # Paid most recently wrote a lifecycle state that disagrees with what
    # this provider change maps to, the change is recorded as a conflict for
    # human review instead of silently overwriting the Paid-side write.
    #
    # @spec UNIFIED-WORK-ITEMS-006
    class ApplyProviderChange
      Result = Data.define(:status, :conflict)

      def self.call(...) = new(...).call

      def initialize(work_item:, native_state:, project: nil, observed_at: Time.current)
        @work_item = work_item
        @native_state = native_state
        @project = project
        @observed_at = observed_at || Time.current
      end

      def call
        return Result.new(status: :rollout_disabled, conflict: nil) unless rollout_enabled?

        work_item.with_lock { apply_change }
      end

      private

      def apply_change
        return Result.new(status: :unchanged, conflict: nil) if work_item.native_state == native_state

        return conflict_result if conflicting?

        apply
        Result.new(status: mapped_paid_state ? :applied : :unsupported, conflict: nil)
      end

      attr_reader :work_item, :native_state, :project, :observed_at

      def rollout_enabled?
        guard = Automation::Providers::UnifiedWorkItemsRolloutGuard
        project ? guard.enabled?(project) : guard.enabled_for_account?(work_item.account)
      end

      def mapped_paid_state
        @mapped_paid_state ||= WorkItemLifecycleMapping.paid_state_for(account: work_item.account,
          provider: work_item.provider, native_state:, project:)
      end

      def conflicting?
        work_item.lifecycle_synced_at.present? && work_item.lifecycle_synced_at > observed_at &&
          work_item.lifecycle_sync_source == "paid" && work_item.paid_lifecycle_state.present? &&
          mapped_paid_state.present? && mapped_paid_state != work_item.paid_lifecycle_state
      end

      def conflict_result
        conflict = work_item.work_item_lifecycle_conflicts.create!(account: work_item.account,
          requested_native_state: native_state, requested_paid_state: mapped_paid_state,
          observed_native_state: work_item.native_state, observed_paid_state: work_item.paid_lifecycle_state,
          detected_at: Time.current)
        Result.new(status: :conflict, conflict:)
      end

      def apply
        work_item.update!(native_state:, paid_lifecycle_state: mapped_paid_state || work_item.paid_lifecycle_state,
          lifecycle_sync_source: "provider", lifecycle_synced_at: Time.current)
      end
    end
  end
end
