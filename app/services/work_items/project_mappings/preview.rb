# frozen_string_literal: true

module WorkItems
  module ProjectMappings
    # Computes the effect of a Linear-project mapping change (create or
    # update) without writing anything, so a mapping change can be reviewed
    # and confirmed before any assignment is created, removed, or flagged.
    #
    # @spec UNIFIED-WORK-ITEMS-004
    class Preview
      Result = Data.define(:mapping, :to_assign, :to_unassign, :needs_review)

      def self.call(...) = new(...).call

      def initialize(account:, provider:, native_project_id:, target_projects:, assignment_mode:)
        @account = account
        @provider = provider
        @native_project_id = native_project_id
        @target_projects = target_projects
        @assignment_mode = assignment_mode
      end

      def call
        Result.new(mapping: existing_mapping, to_assign:, to_unassign:, needs_review:)
      end

      private

      attr_reader :account, :provider, :native_project_id, :target_projects, :assignment_mode

      def existing_mapping
        account.work_item_project_mappings.find_by(provider:, native_project_id:)
      end

      def matching_work_items
        account.work_items.where(provider:, native_project_id:)
      end

      def locked_work_item_ids
        WorkItemAssignment.where(work_item_id: matching_work_items.select(:id), locked: true)
          .distinct.pluck(:work_item_id)
      end

      def to_assign
        return WorkItem.none unless assignment_mode == "current_and_future"

        matching_work_items.where.not(id: locked_work_item_ids)
      end

      def to_unassign
        return WorkItemAssignment.none if existing_mapping.nil?

        removed_project_ids = existing_mapping.project_ids - target_projects.map(&:id)
        return WorkItemAssignment.none if removed_project_ids.empty?

        WorkItemAssignment.where(work_item_project_mapping_id: existing_mapping.id, project_id: removed_project_ids)
      end

      def needs_review
        matching_work_items.where(id: locked_work_item_ids)
      end
    end
  end
end
