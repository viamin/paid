# frozen_string_literal: true

module WorkItems
  # Resolves which assigned project a Paid run started from this work item
  # should execute in: an explicit issue-level default wins; otherwise the
  # mapping-level default; otherwise the caller must prompt for a choice
  # among the work item's assigned projects.
  #
  # @spec UNIFIED-WORK-ITEMS-004
  class ExecutionProjectResolver
    def self.call(...) = new(...).call

    def initialize(work_item:)
      @work_item = work_item
    end

    def call
      issue_level_default || mapping_level_default
    end

    # The projects a caller may choose among when no default resolves.
    def candidates
      work_item.projects
    end

    private

    attr_reader :work_item

    def issue_level_default
      work_item.work_item_assignments.default_execution.first&.project
    end

    def mapping_level_default
      mapping = work_item.work_item_assignments.where(provenance: "mapping")
        .find { |assignment| assignment.work_item_project_mapping&.default_execution_project_id }
      mapping&.work_item_project_mapping&.default_execution_project
    end
  end
end
