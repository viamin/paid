# frozen_string_literal: true

module PostDeployMeasurements
  # Resolves the deployment generation a measurement must run against. The
  # target comes from the issue's terminal closeout evidence — its most
  # recent merged PR — and the authoritative `deployed_at` signal. A merged
  # PR not yet marked deployed is a routine wait, never a pass; no merged PR
  # is a named recovery action.
  # @spec POST-DEPLOY-003
  class DeploymentTarget
    Status = Data.define(:state, :pr_number, :revision, :deployed_at, :recovery) do
      def deployed? = state == :deployed

      def self.awaiting(pr_number)
        new(state: :awaiting_deployment, pr_number: pr_number, revision: nil, deployed_at: nil,
          recovery: "Mark merged PR ##{pr_number} as deployed; the check re-runs automatically after that.")
      end

      def self.missing
        new(state: :no_revision, pr_number: nil, revision: nil, deployed_at: nil,
          recovery: "No merged PR is linked to this issue yet; a post-deploy measurement needs the " \
                    "implementing PR and its deployment first.")
      end
    end

    def self.resolve(issue)
      candidate = deployed_candidate(issue)
      return Status.missing unless candidate

      if candidate.deployed_at.present?
        Status.new(state: :deployed, pr_number: candidate.github_number,
          revision: revision_for(candidate), deployed_at: candidate.deployed_at, recovery: nil)
      else
        Status.awaiting(candidate.github_number)
      end
    end

    # Stable per deployment event: re-marking a deployment produces a new
    # generation so prior evidence becomes visibly stale rather than wrong.
    def self.revision_for(pr)
      "pr-#{pr.github_number}@#{pr.deployed_at.utc.iso8601}"
    end

    def self.deployed_candidate(issue)
      evidence = Issues::CloseoutEvidence.call(issue)
      return nil if evidence.merged_prs.empty?

      numbers = evidence.merged_prs.map(&:number)
      issue.project.issues.where(is_pull_request: true, github_number: numbers).order(:deployed_at, :id).last
    end
  end
end
