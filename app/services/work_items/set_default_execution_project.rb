# frozen_string_literal: true

module WorkItems
  # Sets (or clears) a work item's issue-level default execution project.
  # The project must already be one of the work item's assigned projects.
  #
  # @spec UNIFIED-WORK-ITEMS-004
  class SetDefaultExecutionProject
    NotAssignedError = Class.new(StandardError)

    def self.call(...) = new(...).call

    def initialize(work_item:, project:)
      @work_item = work_item
      @project = project
    end

    def call
      assignment = project && work_item.work_item_assignments.find_by(project:)
      raise NotAssignedError, "project must be assigned to the work item first" if project && assignment.nil?

      WorkItemAssignment.transaction do
        work_item.work_item_assignments.update_all(default_execution: false)
        assignment&.update!(default_execution: true)
      end
      work_item
    end

    private

    attr_reader :work_item, :project
  end
end
