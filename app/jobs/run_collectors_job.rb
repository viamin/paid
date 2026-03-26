# frozen_string_literal: true

class RunCollectorsJob < ApplicationJob
  queue_as :default

  def perform(project_id, commit_sha, branch: "main", committed_at: nil)
    project = Project.find(project_id)

    if Knowledge::ContainerizedRunner.available?
      Knowledge::ContainerizedRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    else
      Knowledge::CollectorRunner.call(
        project: project,
        commit_sha: commit_sha,
        branch: branch,
        committed_at: committed_at
      )
    end
  end
end
