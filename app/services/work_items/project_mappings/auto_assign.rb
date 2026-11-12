# frozen_string_literal: true

module WorkItems
  module ProjectMappings
    # Applies an existing current-and-future mapping to one freshly synced
    # work item, so "future" tickets in a mapped Linear project keep landing
    # in the mapped Paid project(s) without a human repeating the mapping.
    # A locked (overridden) item is left untouched.
    #
    # @spec UNIFIED-WORK-ITEMS-004
    class AutoAssign
      def self.call(...) = new(...).call

      def initialize(work_item:, previous_native_project_id: nil)
        @work_item = work_item
        @previous_native_project_id = previous_native_project_id
      end

      def call
        reconcile_previous_mapping
        return if work_item.locked_from_mapping?
        return unless eligible_for_auto_assignment?

        mapping.projects.each do |project|
          next unless Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project)

          work_item.work_item_assignments.find_or_create_by!(project:) do |assignment|
            assignment.account = work_item.account
            assignment.provenance = "mapping"
            assignment.work_item_project_mapping = mapping
          end
        end
      end

      private

      attr_reader :work_item, :previous_native_project_id

      def reconcile_previous_mapping
        return unless native_project_changed?
        return unless previous_mapping

        previous_assignments = work_item.work_item_assignments.where(work_item_project_mapping: previous_mapping)
        if previous_assignments.where(locked: true).exists?
          work_item.flag_for_review!
        else
          previous_assignments.destroy_all
        end
      end

      def native_project_changed?
        previous_native_project_id.present? && previous_native_project_id != work_item.native_project_id
      end

      def previous_mapping
        @previous_mapping ||= work_item.account.work_item_project_mappings
          .find_by(provider: work_item.provider, native_project_id: previous_native_project_id)
      end

      def mapping
        @mapping ||= work_item.account.work_item_project_mappings
          .find_by(provider: work_item.provider, native_project_id: work_item.native_project_id)
      end

      def eligible_for_auto_assignment?
        return false if mapping.nil? || work_item.locked_from_mapping?
        return true if mapping.current_and_future?

        mapping.future_only? && work_item.created_at >= mapping.created_at
      end
    end
  end
end
