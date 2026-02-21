# frozen_string_literal: true

# Background job that indexes a project's source code for semantic search.
#
# Walks the repository, chunks code into searchable units, and stores
# them as CodeChunk records. Designed for incremental re-indexing via
# content hashing.
#
# @example Enqueue indexing for a project
#   IndexProjectJob.perform_later(project.id, "/path/to/repo")
class IndexProjectJob < ApplicationJob
  queue_as :default

  def perform(project_id, repo_path)
    project = Project.find(project_id)

    Rails.logger.info(
      message: "semantic_search.index_started",
      project_id: project.id,
      repo_path: repo_path
    )

    stats = SemanticSearch::IndexProject.call(project: project, repo_path: repo_path)

    Rails.logger.info(
      message: "semantic_search.index_finished",
      project_id: project.id,
      **stats
    )
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn(
      message: "semantic_search.index_skipped",
      error: e.message
    )
  end
end
