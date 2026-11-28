# frozen_string_literal: true

module MainCi
  # @spec MAIN-CI-001 MAIN-CI-002 MAIN-CI-006
  class Snapshot
    attr_reader :head, :runs

    def initialize(project:, client:, event: "push", sha: nil)
      @policy = Policy.new(project)
      @project = project
      @client = client
      @head = client.default_branch_head(project.full_name)
      @sha = sha || head.fetch(:sha)
      @event = event
      @runs = client.full_verification_runs(project.full_name, sha: @sha, branch: head.fetch(:branch), event: event)
    end

    def required_runs
      return [] unless @policy.valid?

      runs.select do |run|
        @policy.workflows.include?(run[:path]) && run[:head_sha] == @sha &&
          run[:event] == @event && (@event != "push" || run[:head_branch] == head[:branch])
      end.group_by { |run| run[:path] }.values.map { |group| group.max_by { |run| run.fetch(:id) } }
    end

    def green?
      @policy.valid? && required_runs.size == @policy.workflows.size &&
        required_runs.all? { |run| run[:status] == "completed" && run[:conclusion] == "success" }
    end

    def recent_failures
      recent = @client.full_verification_runs(@project.full_name, branch: head.fetch(:branch))
      recent.select do |run|
        @policy.workflows.include?(run[:path]) && run[:event] == "push" && run[:head_branch] == head[:branch]
      end.group_by { |run| [ run[:path], run[:head_sha] ] }.values.map { |group| group.max_by { |run| run.fetch(:id) } }
        .select { |run| run[:status] == "completed" && %w[failure timed_out cancelled action_required startup_failure].include?(run[:conclusion]) }
        .max_by { |run| run.fetch(:id) }.then { |run| run ? [ run ] : [] }
    end

    def failures
      required_runs.select { |run| run[:status] == "completed" && %w[failure timed_out cancelled action_required startup_failure].include?(run[:conclusion]) }
    end
  end
end
