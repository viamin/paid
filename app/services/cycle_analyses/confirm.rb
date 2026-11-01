# frozen_string_literal: true

module CycleAnalyses
  # Confirms an already-written repair from the locally synchronized graph.
  # It intentionally has no GitHub client: retrying confirmation must never
  # reapply the declaration mutation.
  class Confirm
    Result = Data.define(:status, :reason, :changed_edge_ids, :details) do
      def to_h = { "status" => status, "reason" => reason, "changed_edge_ids" => changed_edge_ids, "details" => details }
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    # @spec AUTO-PICK-QUEUE-019
    def call
      cycles = Issues::DependencyCycles.call(account: agent_run.project.account)
      return result("pending_sync", "awaiting_github_synchronization") if original_cycle?(cycles)
      return result("needs_operator_action", "graph_changed") if related_cycle?(cycles)

      result("resolved", "synchronization_confirmed")
    end

    private

    attr_reader :agent_run

    def snapshot = agent_run.external_metadata.fetch(METADATA_KEY)

    def original_cycle?(cycles)
      cycles.any? { |cycle| cycle.occurrence == snapshot.fetch("occurrence") }
    end

    def related_cycle?(cycles)
      issue_ids = snapshot.fetch("issues").pluck("id")
      cycles.any? { |cycle| (cycle.issues.map(&:id) & issue_ids).any? }
    end

    def result(status, reason)
      Result.new(status, reason, previous_repair.fetch("changed_edge_ids", []), {}).to_h
    end

    def previous_repair
      agent_run.verification_result.fetch(RESULT_KEY).fetch("repair")
    end
  end
end
