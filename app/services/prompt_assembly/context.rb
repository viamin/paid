# frozen_string_literal: true

module PromptAssembly
  # Identifies the run context a prompt is being assembled for. Carries the
  # goal plus the project and agent run so providers and provenance can
  # attribute sections to a concrete run without reaching for globals.
  class Context
    attr_reader :goal, :project, :agent_run

    def initialize(goal:, project: nil, agent_run: nil)
      @goal = goal
      @project = project
      @agent_run = agent_run
    end

    def self.for_agent_run(agent_run)
      new(goal: agent_run.goal, project: agent_run.project, agent_run: agent_run)
    end
  end
end
