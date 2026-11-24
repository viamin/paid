# frozen_string_literal: true

module Issues
  # Records a deliberate operator authorization without changing the PR's true parent.
  # @spec PARTIAL-CLOSEOUT-060
  class AssociateSharedDeliveryEvidence
    def self.call(...) = new(...).call
    def initialize(issue:, pull_request:, actor:) = (@issue = issue; @pull_request = pull_request; @actor = actor)
    def call
      authorize!
      issue.with_lock do
        SharedDeliveryEvidenceAssociation.create!(account: issue.project.account, project: issue.project,
          issue:, pull_request:, authorized_by: actor, pull_request_url: canonical_pull_request_url,
          revision: pull_request.merged_commit_sha)
      end
    end
    private
    attr_reader :actor, :issue, :pull_request

    def authorize!
      raise Pundit::NotAuthorizedError unless ProjectPolicy.new(actor, issue.project).manage_issues?
    end

    def canonical_pull_request_url
      SharedDeliveryEvidenceAssociation.canonical_url_for(pull_request)
    end
  end
end
