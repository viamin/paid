# frozen_string_literal: true

module Coordination
  # Collects shared context from completed sibling runs within a workflow,
  # including changed files, context signals, and sequencing hints. This
  # context can be injected into an agent's prompt so it is aware of work
  # already completed by related runs.
  #
  # @example
  #   result = Coordination::SharedContext.call(agent_run: run)
  #   result.changed_files  # => ["app/models/user.rb"]
  #   result.context_entries # => [{ source_run_id: 1, ... }]
  class SharedContext
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      unless agent_run.parent_workflow_id.present?
        return Result.new(changed_files: [], context_entries: [], sequencing_hints: [])
      end

      workflow_id = agent_run.parent_workflow_id

      changed_files = AgentCoordinationSignal.changed_files_for_workflow(workflow_id)

      context_entries = AgentCoordinationSignal
        .visible_to(agent_run)
        .by_type("context_shared")
        .order(:created_at)
        .map { |s| { source_run_id: s.source_agent_run_id, payload: s.payload } }

      sequencing_hints = AgentCoordinationSignal
        .sequencing_hints_for(agent_run)
        .map { |s| { source_run_id: s.source_agent_run_id, payload: s.payload } }

      Result.new(
        changed_files: changed_files,
        context_entries: context_entries,
        sequencing_hints: sequencing_hints
      )
    end

    private

    attr_reader :agent_run

    class Result
      attr_reader :changed_files, :context_entries, :sequencing_hints

      def initialize(changed_files:, context_entries:, sequencing_hints:)
        @changed_files = changed_files
        @context_entries = context_entries
        @sequencing_hints = sequencing_hints
      end

      def any_context?
        changed_files.any? || context_entries.any? || sequencing_hints.any?
      end
    end
  end
end
