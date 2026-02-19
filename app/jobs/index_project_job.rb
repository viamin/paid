# frozen_string_literal: true

# Indexes a project's source code for semantic search.
#
# Walks the repository file tree, chunks code into searchable segments,
# and optionally generates vector embeddings for semantic similarity search.
#
# Triggered when:
# - A project is first created
# - A webhook indicates new commits pushed
# - Manually via admin interface
#
# Uses content hashing for incremental sync — only changed files are re-indexed.
class IndexProjectJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(project_id, repo_path:)
    project = Project.find(project_id)

    stats = SemanticSearch::IndexProject.call(
      project: project,
      repo_path: repo_path
    )

    Rails.logger.info(
      message: "semantic_search.job_complete",
      project_id: project_id,
      stats: stats
    )

    # Generate embeddings for newly indexed chunks (when provider is configured)
    SemanticSearch::GenerateEmbeddings.call(project: project)
  end
end
