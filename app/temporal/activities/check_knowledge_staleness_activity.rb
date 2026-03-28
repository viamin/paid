# frozen_string_literal: true

module Activities
  # Checks whether a project's knowledge base is stale and triggers
  # re-collection when necessary. Runs as part of the GitHubPollWorkflow
  # after issue fetching.
  class CheckKnowledgeStalenessActivity < BaseActivity
    activity_name "CheckKnowledgeStaleness"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { stale: false, project_missing: true } unless project

      result = Knowledge::Staleness::Detector.call(project: project)

      log_staleness(project, result) if result[:stale]

      result.slice(
        :stale,
        :current_sha,
        :last_collected_sha,
        :changed_files,
        :stale_artifacts_count,
        :collection_enqueued
      )
    rescue => e
      logger.error(
        message: "knowledge.staleness_check_failed",
        project_id: input[:project_id],
        error: e.message
      )
      { stale: false, error: e.message }
    end

    private

    def log_staleness(project, result)
      logger.info(
        message: "knowledge.staleness_detected",
        project_id: project.id,
        current_sha: result[:current_sha],
        last_collected_sha: result[:last_collected_sha],
        changed_files_count: result[:changed_files].size,
        stale_artifacts_count: result[:stale_artifacts_count],
        collection_enqueued: result[:collection_enqueued]
      )
    end
  end
end
