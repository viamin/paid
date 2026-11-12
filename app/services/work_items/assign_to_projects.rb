# frozen_string_literal: true

module WorkItems
  # Individual or bulk manual assignment of work items to repository-backed
  # Paid projects. Idempotent: re-assigning an already-assigned pair is a
  # no-op. Never touches an existing `locked` (overridden) assignment's
  # projects; it only adds new ones.
  #
  # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-009
  class AssignToProjects
    def self.call(...) = new(...).call

    def initialize(work_items:, projects:, actor: nil)
      @work_items = Array(work_items)
      @projects = Array(projects)
      @actor = actor
    end

    def call
      enabled_projects = projects.select { |project| Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project) }
      return [] if enabled_projects.empty?

      WorkItemAssignment.transaction do
        work_items.flat_map { |work_item| assign_one(work_item, enabled_projects) }
      end
    end

    private

    attr_reader :work_items, :projects, :actor

    def assign_one(work_item, enabled_projects)
      enabled_projects.filter_map do |project|
        next if work_item.work_item_assignments.exists?(project_id: project.id)

        work_item.work_item_assignments.create!(account: work_item.account, project:,
          provenance: "manual", assigned_by: actor)
      end
    end
  end
end
