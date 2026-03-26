# frozen_string_literal: true

class RunCollectorsJob < ApplicationJob
  queue_as :default

  def perform(project_id, commit_sha, branch: "main")
    project = Project.find(project_id)

    Knowledge::CollectorRunner.call(
      project: project,
      commit_sha: commit_sha,
      branch: branch
    )
  end
end
