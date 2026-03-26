# frozen_string_literal: true

module Activities
  # Runs knowledge collectors inside a containerized environment.
  #
  # Provisions a lightweight Docker container with the project cloned at
  # the target commit SHA, runs all registered collectors, and extracts
  # results to Postgres. No API keys or secrets are exposed.
  #
  # Falls back to host execution when Docker is unavailable.
  class RunCollectorsActivity < BaseActivity
    activity_name "RunCollectors"

    def execute(input)
      project_id = input[:project_id]
      commit_sha = input[:commit_sha]
      branch = input.fetch(:branch, "main")
      committed_at = input[:committed_at]

      project = Project.find(project_id)

      result = if Knowledge::ContainerizedRunner.available?
        run_containerized(project, commit_sha, branch, committed_at)
      else
        run_on_host(project, commit_sha, branch, committed_at)
      end

      {
        project_id: project_id,
        commit_sha: commit_sha,
        success: true,
        containerized: Knowledge::ContainerizedRunner.available?,
        results: result[:results].map { |r| r.slice(:collector_type, :status, :artifacts_count) }
      }
    rescue Knowledge::ContainerizedRunner::Error => e
      logger.error(
        message: "knowledge.containerized_runner_failed",
        project_id: project_id,
        commit_sha: commit_sha,
        error: e.message
      )
      raise Temporalio::Error::ApplicationError.new(
        "Containerized collector execution failed: #{e.message}",
        type: "CollectorContainerError"
      )
    end

    private

    def run_containerized(project, commit_sha, branch, committed_at)
      Knowledge::ContainerizedRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    end

    def run_on_host(project, commit_sha, branch, committed_at)
      Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    end
  end
end
