# frozen_string_literal: true

module WorkItems
  module Lifecycle
    # Applies a Paid-side lifecycle change and, when the mapping and project
    # settings permit, pushes the mapped native state to the provider. An
    # agent-run-driven change honors the project's independent
    # `agent_run_lifecycle_sync_enabled` toggle; a human-driven change does
    # not. Loop prevention and conflict review mirror ApplyProviderChange.
    #
    # @spec UNIFIED-WORK-ITEMS-006 UNIFIED-WORK-ITEMS-009
    class ApplyPaidChange
      Result = Data.define(:status, :conflict)

      def self.call(...) = new(...).call

      def initialize(work_item:, paid_state:, project: nil, agent_run: nil)
        @work_item = work_item
        @paid_state = paid_state
        @project = project
        @agent_run = agent_run
        @observed_lifecycle_synced_at = work_item.lifecycle_synced_at
      end

      def call
        return Result.new(status: :rollout_disabled, conflict: nil) unless rollout_enabled?

        work_item.with_lock { apply_change }
      end

      private

      def apply_change
        return Result.new(status: :unchanged, conflict: nil) if work_item.paid_lifecycle_state == paid_state
        return Result.new(status: :agent_run_sync_disabled, conflict: nil) if agent_run_sync_disabled?
        return conflict_result if conflicting?

        push_to_provider if provider_sync_supported?
        apply
        Result.new(status: provider_sync_supported? ? :applied : :unsupported, conflict: nil)
      end

      attr_reader :work_item, :paid_state, :project, :agent_run, :observed_lifecycle_synced_at

      def rollout_enabled?
        guard = Automation::Providers::UnifiedWorkItemsRolloutGuard
        project ? guard.enabled?(project) : guard.enabled_for_account?(work_item.account)
      end

      def agent_run_sync_disabled?
        return false unless agent_run

        project.present? && !project.agent_run_lifecycle_sync_enabled
      end

      def mapped_native_state
        @mapped_native_state ||= WorkItemLifecycleMapping.native_state_for(account: work_item.account,
          provider: work_item.provider, paid_state:, project:)
      end

      def conflicting?
        work_item.lifecycle_synced_at != observed_lifecycle_synced_at &&
          work_item.lifecycle_sync_source == "provider" && work_item.native_state.present? &&
          mapped_native_state.present? && mapped_native_state != work_item.native_state
      end

      def conflict_result
        conflict = work_item.work_item_lifecycle_conflicts.create!(account: work_item.account,
          requested_paid_state: paid_state, requested_native_state: mapped_native_state,
          observed_paid_state: work_item.paid_lifecycle_state, observed_native_state: work_item.native_state,
          detected_at: Time.current)
        Result.new(status: :conflict, conflict:)
      end

      def apply
        work_item.update!(paid_lifecycle_state: paid_state, lifecycle_sync_source: "paid",
          lifecycle_synced_at: Time.current)
      end

      def push_to_provider
        work_item.tracker_configuration.adapter.update_status(external_id: work_item.external_id,
          status: mapped_native_state)
      end

      def provider_sync_supported?
        mapped_native_state.present? && work_item.tracker_configuration&.enabled?
      end
    end
  end
end
