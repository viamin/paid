# frozen_string_literal: true

module Tools
  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-018
  class StartCycleAnalysis < BaseTool
    authorize :run_agent?, ->(args) { cycle_for(args.fetch(:occurrence_id)).project }, policy_class: ProjectPolicy

    def self.tool_name = "start_cycle_analysis"
    def self.write_operation? = true

    def self.description
      "Start a read-only analysis for a dependency-cycle Inbox occurrence. Requires confirmation and run-agent authorization for every project in the cycle."
    end

    def self.input_schema
      { type: "object", properties: { occurrence_id: { type: "string" }, confirmed: { type: "boolean" } }, required: %w[occurrence_id confirmed] }
    end

    def perform(occurrence_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to start cycle analysis" unless confirmed

      cycle = cycle_for(occurrence_id)

      cycle.project_ids.each { |project_id| authorize Project.find(project_id), :run_agent?, policy_class: ProjectPolicy }
      run = DependencyCycles::StartAnalysis.call(cycle:, user:)
      ProcessRunQueueJob.perform_later
      { id: run.id, status: run.status, graph_revision: cycle.graph_revision }
    rescue DependencyCycles::StartAnalysis::ActiveRunExists
      raise ArgumentError, "A cycle analysis is already queued or running for this occurrence"
    end

    private

    def cycle_for(occurrence_id)
      Issues::DependencyCycles.call(account:).find { |candidate| candidate.id == occurrence_id }.tap do |cycle|
        raise ArgumentError, "Dependency-cycle occurrence is no longer available" unless cycle
      end
    end
  end
end
