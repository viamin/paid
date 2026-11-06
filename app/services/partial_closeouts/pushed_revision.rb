# frozen_string_literal: true

module PartialCloseouts
  # Confirms that the exact revision the agent pushed is still the branch head
  # before a recovery re-assesses it.
  #
  # A moved or deleted branch means the recorded revision is gone: recovering
  # against different content would publish a pull request for work the run
  # never produced, so the recovery refuses instead.
  # @spec PARTIAL-CLOSEOUT-044
  class PushedRevision
    Result = Data.define(:current, :reason, :message) do
      def current? = current

      # A transient lookup failure is not the same as a moved branch: the
      # branch may still be exactly where the run pushed it.
      def transient? = reason == "lookup_unavailable"
    end

    def self.call(agent_run:) = new(agent_run:).call

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return missing("missing_branch", "This run has no pushed branch to recover.") if agent_run.branch_name.blank?
      return missing("missing_commit", "This run has no pushed commit to recover.") if agent_run.result_commit_sha.blank?

      head = remote_head_sha
      return missing("lookup_unavailable", "The pushed branch could not be verified right now.") if head == :unavailable
      return missing("branch_missing", "The pushed branch #{agent_run.branch_name} no longer exists on GitHub.") if head.nil?
      return current_result if head == agent_run.result_commit_sha

      missing(
        "branch_moved",
        "The pushed branch #{agent_run.branch_name} moved to #{head[0..7]} after this run pushed #{agent_run.result_commit_sha[0..7]}."
      )
    end

    private

    attr_reader :agent_run

    def current_result
      Result.new(current: true, reason: "current", message: "The pushed revision is still the branch head.")
    end

    def missing(reason, message)
      Result.new(current: false, reason: reason, message: message)
    end

    def remote_head_sha
      ref = agent_run.project.client.ref(agent_run.project.full_name, "heads/#{agent_run.branch_name}")
      ref.object.sha.to_s
    rescue GithubClient::NotFoundError
      nil
    rescue StandardError => e
      Rails.logger.warn(
        message: "partial_closeout.pushed_revision_lookup_failed",
        agent_run_id: agent_run.id,
        branch: agent_run.branch_name,
        error_class: e.class.name
      )
      :unavailable
    end
  end
end
