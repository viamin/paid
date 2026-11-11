# frozen_string_literal: true

module WorkItems
  module Overrides
    # Adds project(s) to a work item's existing mapping-driven assignment
    # without removing any of them, then locks the whole item so a future
    # mapping change flags it for review instead of silently altering it.
    #
    # @spec UNIFIED-WORK-ITEMS-004
    class Customize
      def self.call(...) = new(...).call

      def initialize(work_item:, projects:, actor: nil, note: nil)
        @work_item = work_item
        @projects = Array(projects).select { |project| Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project) }
        @actor = actor
        @note = note
      end

      def call
        WorkItemAssignment.transaction do
          projects.each { |project| ensure_assignment(project) }
          work_item.work_item_assignments.update_all(locked: true)
          work_item.work_item_assignment_overrides.create!(account: work_item.account, mode: "customized", actor:, note:)
          work_item.clear_review_flag!
        end
        work_item.reload
      end

      private

      attr_reader :work_item, :projects, :actor, :note

      def ensure_assignment(project)
        work_item.work_item_assignments.find_or_create_by!(project:) do |assignment|
          assignment.account = work_item.account
          assignment.provenance = "manual"
          assignment.assigned_by = actor
        end
      end
    end
  end
end
