# frozen_string_literal: true

module PullRequests
  # Re-publishes only Paid's source-issue reference immediately before an
  # automatic merge. The semantic assessment is already persisted; this
  # boundary merely binds it to the fetched head and publishes the fail-closed
  # result. It never edits closed PRs.
  # @spec PARTIAL-CLOSEOUT-050
  class RefreshSourceClosure
    Result = Data.define(:evaluated, :updated, :disposition, :source_issue)

    def self.call(...) = new(...).call

    def initialize(pull_request:, pull_request_data:, client: nil)
      @pull_request = pull_request
      @pull_request_data = pull_request_data
      @client = client
    end

    def call
      return Result.new(evaluated: false, updated: false, disposition: nil, source_issue: nil) unless open_pull_request?

      source = source_issue
      run = producing_run
      return Result.new(evaluated: false, updated: false, disposition: nil, source_issue: nil) unless source && run

      disposition = PartialCloseouts::SourceClosureDisposition.for_pull_request(
        issue: source, assessment: PartialCloseouts::Assessment.call(source).assessment, head_sha: pull_request_data.head_sha,
        verification_revision: PartialCloseouts::Assessment.verification_revision_for(run)
      ).fetch("disposition")
      body = SourceClosureBody.call(body: pull_request_data.body, issue: source, project: pull_request.project, disposition:)
      updated = body != pull_request_data.body.to_s
      update_pull_request(body) if updated
      Result.new(evaluated: true, updated:, disposition:, source_issue: source)
    end

    private

    attr_reader :pull_request, :pull_request_data, :client

    def open_pull_request?
      !pull_request_data.merged && pull_request.github_state == "open"
    end

    def source_issue
      pull_request.parent_issue || producing_run&.issue
    end

    def update_pull_request(body)
      update_client.update_pull_request(
        pull_request.project.pr_target_repository, pull_request.github_number, body:
      )
    end

    def update_client
      client.respond_to?(:call) ? client.call : client || pull_request.project.client
    end

    def producing_run
      @producing_run ||= pull_request.project.agent_runs.where(
        goal: "create_pr", pull_request_number: pull_request.github_number, pull_request_url: pull_request.github_url
      ).order(id: :desc).first
    end
  end
end
