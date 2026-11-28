# frozen_string_literal: true

module MainCi
  # This gate adds a technical stop; callers retain their normal review gates.
  # @spec MAIN-CI-002 MAIN-CI-005 MAIN-CI-006
  module MergeGate
    module_function

    def blocked?(issue)
      project = issue.project
      return false unless Policy.new(project).enabled?

      state = MainCiState.find_by(project: project)
      return true unless state
      return false unless state.blocked?

      !repair?(state, issue.github_number, state.repair_run&.result_commit_sha)
    end

    def allowed?(project:, number:, head_sha:, client:)
      return true unless Policy.new(project).enabled?
      return false unless Policy.new(project).valid?

      state = MainCiState.find_by(project: project)
      return false unless state
      unless state.blocked?
        snapshot = Snapshot.new(project: project, client: client)
        return snapshot.head[:sha] == state.verified_sha && snapshot.green? &&
          client.default_branch_head(project.full_name) == snapshot.head
      end
      return false unless repair?(state, number, head_sha)

      Snapshot.new(project: project, client: client, event: "pull_request", sha: head_sha).green?
    rescue GithubClient::Error
      false
    end

    def repair?(state, number, head_sha)
      run = state.repair_run
      state.episode_key.present? && run && run.external_metadata["main_ci_episode"] == state.episode_key &&
        run.pull_request_number == number && head_sha.present? && run.result_commit_sha == head_sha
    end
  end
end
