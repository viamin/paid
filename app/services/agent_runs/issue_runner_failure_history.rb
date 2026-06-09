# frozen_string_literal: true

module AgentRuns
  # Computes per-runner failure counts from previous agent runs for the same issue.
  # Used by RunAgentActivity to implement issue-aware provider switching: providers
  # that have already failed for a given issue are deprioritized so that untried
  # providers are attempted first.
  #
  # Only actual execution failures (error, timeout, infinite_loop, preflight_timeout)
  # are counted. Rate limits, skipped runners, and externally-cancelled runs are
  # excluded because they do not reflect provider quality for the specific issue.
  class IssueRunnerFailureHistory
    # Error types indicating an actual execution failure (not transient or external).
    EXECUTION_FAILURE_TYPES = %w[error timeout infinite_loop preflight_timeout].freeze

    # Maximum number of prior runs to inspect. Avoids unbounded queries on issues
    # with hundreds of retry attempts.
    MAX_PRIOR_RUNS = 20

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    # Returns a hash of { canonical_runner_key => failure_count } from all prior
    # failed runs for the same issue/project/goal combination.
    # Canonical runner keys are normalized (e.g. "claude_code" -> "claude").
    def call
      return {} unless agent_run.issue_id

      runs = prior_runs
      return {} if runs.empty?

      routing_key_map = build_routing_key_map(runs)

      runs.each_with_object(Hash.new(0)) do |run, counts|
        run.runners_attempted.each do |attempt|
          next if attempt["success"]
          next unless EXECUTION_FAILURE_TYPES.include?(attempt["error_type"])

          label = attempt["runner"] || attempt["provider"]
          key = canonical_runner_key(label, routing_key_map)
          next unless key

          counts[key] += 1
        end
      end
    end

    private

    attr_reader :agent_run

    def prior_runs
      AgentRun
        .where(project_id: agent_run.project_id, issue_id: agent_run.issue_id, goal: agent_run.goal)
        .where.not(id: agent_run.id)
        .where("runners_attempted != '[]'::jsonb")
        .order(created_at: :desc)
        .limit(MAX_PRIOR_RUNS)
    end

    # Builds a map from routing key -> canonical runner_key for all routing-key-style
    # attempt labels referenced across the given runs. Batches the DB lookup.
    def build_routing_key_map(runs)
      routing_key_ids = runs.flat_map do |run|
        run.runners_attempted.filter_map do |attempt|
          label = attempt["runner"] || attempt["provider"]
          Runner.id_from_routing_key(label.to_s)
        end
      end.uniq
      return {} if routing_key_ids.empty?

      Runner.with_discarded.where(id: routing_key_ids).each_with_object({}) do |runner, map|
        map[runner.routing_key] = runner.runner_key
        map[runner.legacy_routing_key] = runner.runner_key
      end
    end

    # Returns the canonical runner key for an attempt label.
    # Routing keys are resolved via the pre-built map; agent type aliases
    # ("claude_code") are normalized via AGENT_TYPE_TO_RUNNER.
    def canonical_runner_key(runner_label, routing_key_map)
      return unless runner_label.present?

      if Runner.routing_key?(runner_label)
        key = routing_key_map[runner_label]
        return unless key

        Activities::RunAgentActivity::AGENT_TYPE_TO_RUNNER.fetch(key, key)
      else
        key = Activities::RunAgentActivity::AGENT_TYPE_TO_RUNNER.fetch(runner_label, runner_label)
        key.presence
      end
    end
  end
end
