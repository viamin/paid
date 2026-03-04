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
      visited = Set.new
      reachable?(from_issue.id, visited)
    end

    private

    def reachable?(current_id, visited)
      return false unless visited.add?(current_id)

      dependency_ids = IssueDependency.where(issue_id: current_id).pluck(:depends_on_issue_id)

      dependency_ids.each do |dep_id|
        return true if dep_id == target_issue_id
        return true if reachable?(dep_id, visited)
      end

      false
    end
  end
end
