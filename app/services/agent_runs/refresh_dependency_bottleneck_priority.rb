# frozen_string_literal: true

require "set"

module AgentRuns
  # Refreshes a revocable ordering marker from the locally synced dependency graph.
  # It has no admission, claim, or execution-authority side effect.
  # @spec QUEUE-TIER-011
  class RefreshDependencyBottleneckPriority
    def self.call(...) = new(...).call

    def initialize(now: Time.current)
      @now = now
    end

    def call
      candidates_by_project.each { |project, runs| refresh_project(project, runs) }
    end

    private

    attr_reader :now

    def candidates_by_project
      AgentRun.unclaimed.where(status: "queued", trigger_type: "automatic", goal: "create_pr", auto_pick: true,
        source_pull_request_number: nil, continuation_request_id: nil).includes(:project, :issue).to_a
        .select { |run| run.issue_id.present? }.group_by(&:project)
    end

    def refresh_project(project, runs)
      dependents = IssueDependency.where(issue_id: project.issues.select(:id)).where.not(depends_on_issue_id: nil)
        .pluck(:issue_id, :depends_on_issue_id).group_by(&:last).transform_values { |edges| edges.map(&:first) }
      delivery_issue_ids = project.issues.where(is_pull_request: true, github_state: "open")
        .where.not(parent_issue_id: nil).pluck(:parent_issue_id).to_set

      runs.each { |run| update_marker(run, unblocks_active_delivery?(run.issue_id, dependents, delivery_issue_ids)) }
    end

    def unblocks_active_delivery?(issue_id, dependents, delivery_issue_ids)
      frontier = [ issue_id ]
      visited = Set.new
      until frontier.empty?
        current = frontier.shift
        next unless visited.add?(current)
        return true if delivery_issue_ids.include?(current) && current != issue_id

        frontier.concat(dependents.fetch(current, []))
      end
      false
    end

    def update_marker(run, active)
      return if active == run.dependency_bottleneck_priority_requested_at.present?

      run.update_column(:dependency_bottleneck_priority_requested_at, active ? now : nil)
    end
  end
end
