# frozen_string_literal: true

module DesignAmendments
  # Computes the bounded pause set for a design amendment: exactly the
  # affected branches plus their dependency closure (every issue that
  # transitively depends on an affected branch). Pure computation over an
  # adjacency map ({ issue_id => [depends_on_issue_id, ...] }, the shape
  # IssueDependency.project_adjacency returns); no I/O.
  # @spec INTENT-AMENDMENT-006
  class PauseSet
    REASON_AFFECTED = "affected"
    REASON_DEPENDENT = "dependent"

    def self.build(affected_issue_ids:, adjacency:)
      new(affected_issue_ids:, adjacency:).build
    end

    def initialize(affected_issue_ids:, adjacency:)
      @affected_issue_ids = affected_issue_ids.map(&:to_i).to_set
      @adjacency = adjacency
    end

    def build
      pause_set = affected_issue_ids.to_h { |id| [ id, REASON_AFFECTED ] }
      reverse_adjacency = build_reverse_adjacency

      queue = affected_issue_ids.to_a
      seen = affected_issue_ids.dup
      until queue.empty?
        paused_id = queue.shift
        reverse_adjacency.fetch(paused_id, []).each do |dependent_id|
          next if seen.include?(dependent_id)

          pause_set[dependent_id] = REASON_DEPENDENT
          seen << dependent_id
          queue << dependent_id
        end
      end

      pause_set
    end

    private

    attr_reader :affected_issue_ids, :adjacency

    def build_reverse_adjacency
      adjacency.each_with_object({}) do |(issue_id, depends_on_ids), reverse|
        Array(depends_on_ids).each do |depends_on_id|
          reverse[depends_on_id.to_i] ||= []
          reverse[depends_on_id.to_i] << issue_id.to_i
        end
      end
    end
  end
end
