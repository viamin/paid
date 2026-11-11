# frozen_string_literal: true

module WorkItems
  module Overrides
    # Completely replaces a work item's assignment with an explicit,
    # human-chosen set of projects and locks the item so a future mapping
    # change flags it for review instead of silently restoring the old set.
    #
    # @spec UNIFIED-WORK-ITEMS-004
    class Replace
      def self.call(...) = new(...).call

      def initialize(work_item:, projects:, actor: nil, note: nil)
        @work_item = work_item
        @projects = Array(projects)
        @actor = actor
        @note = note
      end

      def call
        ensure_rollout_enabled!

        WorkItemAssignment.transaction do
          work_item.work_item_assignments.destroy_all
          projects.each { |project| create_assignment(project) }
          work_item.work_item_assignment_overrides.create!(account: work_item.account, mode: "replaced", actor:, note:)
          work_item.clear_review_flag!
        end
        work_item.reload
      end

      private

      attr_reader :work_item, :projects, :actor, :note

      def ensure_rollout_enabled!
        enabled_projects = projects.select { |project| Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project) }
        raise ArgumentError, "every target project must have unified work items enabled" if enabled_projects != projects
      end

      def create_assignment(project)
        work_item.work_item_assignments.create!(account: work_item.account, project:,
          provenance: "manual", assigned_by: actor, locked: true)
      end
    end
  end
end
