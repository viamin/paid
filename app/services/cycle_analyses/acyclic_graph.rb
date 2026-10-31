# frozen_string_literal: true

module CycleAnalyses
  class AcyclicGraph
    def self.call(...) = new(...).call

    def initialize(issue_ids:, edges:)
      @issue_ids = issue_ids
      @edges = edges
    end

    def call
      pending = indegrees
      ready = pending.filter_map { |issue_id, degree| issue_id if degree.zero? }
      visited = 0

      until ready.empty?
        issue_id = ready.pop
        visited += 1
        outgoing.fetch(issue_id).each do |neighbor|
          pending[neighbor] -= 1
          ready << neighbor if pending[neighbor].zero?
        end
      end

      visited == issue_ids.size
    end

    private

    attr_reader :issue_ids, :edges

    def indegrees
      issue_ids.index_with { 0 }.tap do |degrees|
        edges.each { |edge| degrees[edge.fetch("to_issue_id")] += 1 }
      end
    end

    def outgoing
      @outgoing ||= issue_ids.index_with { [] }.tap do |neighbors|
        edges.each { |edge| neighbors.fetch(edge.fetch("from_issue_id")) << edge.fetch("to_issue_id") }
      end
    end
  end
end
