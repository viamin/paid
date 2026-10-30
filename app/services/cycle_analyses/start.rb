# frozen_string_literal: true

module CycleAnalyses
  class Start
    Result = Data.define(:status, :agent_run, :message) do
      def success? = status == :queued
    end

    def self.call(...) = new(...).call

    def initialize(cycle:, actor:)
      @cycle = cycle
      @actor = actor
    end

    # @spec AUTO-PICK-QUEUE-016
    def call
      AgentRun.transaction do
        lock_occurrence!
        return Result.new(status: :active, agent_run: active_run, message: "Cycle analysis is already active.") if active_run

        run = create_run!
        CycleAnalysisJob.perform_later(run.id)
        Result.new(status: :queued, agent_run: run, message: "Cycle analysis queued.")
      end
    end

    private

    attr_reader :actor, :cycle

    def lock_occurrence!
      AgentRun.connection.exec_query(AgentRun.sanitize_sql_array([
        "SELECT pg_advisory_xact_lock(?, ?)", 4804, Zlib.crc32(cycle.occurrence)
      ]))
    end

    def active_run
      @active_run ||= cycle.project.agent_runs.where(goal: AgentRun::CYCLE_ANALYSIS_GOAL, status: %w[queued running])
        .detect { |run| run.external_metadata.dig(METADATA_KEY, "occurrence") == cycle.occurrence }
    end

    def create_run!
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: cycle.project, goal: AgentRun::CYCLE_ANALYSIS_GOAL)
      AgentRun.create!(project: cycle.project, initiating_user: actor, runner_id:, agent_type:, synthetic: true,
        goal: AgentRun::CYCLE_ANALYSIS_GOAL, trigger_type: "manual", status: "queued",
        custom_prompt: "Analyze dependency cycle #{cycle.occurrence}", external_metadata: { METADATA_KEY => snapshot })
    end

    def snapshot
      {
        "fingerprint" => cycle.fingerprint,
        "occurrence" => cycle.occurrence,
        "graph_revision" => cycle.graph_revision,
        "project_ids" => cycle.project_ids,
        "issue_ids" => cycle.issues.map(&:id),
        "edge_ids" => cycle.effective_edges.map(&:id)
      }
    end
  end
end
