# frozen_string_literal: true

module Issues
  # Detects whether adding a dependency would create a cycle in the dependency
  # graph. Uses depth-first search (DFS) from the proposed dependency to check
  # if it can reach back to the dependent issue.
  #
  # @example
  #   # Would adding "issue depends on dep_issue" create a cycle?
  #   Issues::DetectCycle.call(from_issue: dep_issue, target_issue_id: issue.id)
  #   # => true if cycle would be created
  class DetectCycle
    attr_reader :from_issue, :target_issue_id

    def initialize(from_issue:, target_issue_id:)
      @from_issue = from_issue
      @target_issue_id = target_issue_id
    end

    def self.call(...)
      new(...).call
    end

    def call
      adjacency = load_project_adjacency
      reachable_iterative?(adjacency)
    end

    private

    def load_project_adjacency
      IssueDependency
        .where(issue_id: from_issue.project.issues.select(:id))
        .pluck(:issue_id, :depends_on_issue_id)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last) }
    end

    def reachable_iterative?(adjacency)
      visited = Set.new
      stack = [ from_issue.id ]

      while (current_id = stack.pop)
        next unless visited.add?(current_id)

        (adjacency[current_id] || []).each do |dep_id|
          return true if dep_id == target_issue_id

          stack << dep_id
        end
      end

      false
    end
  end
end
