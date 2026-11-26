# frozen_string_literal: true

require "digest"

module PullRequests
  # Records an explicitly selected evidence-only report without treating its
  # prose as a request for code changes.
  # @spec FOCUSED-RUN-015
  class RecordOperatorAcceptanceReport
    Result = Data.define(:event, :created) do
      def created? = created
    end

    ACTION = "pull_request.operator_acceptance_report_recorded"

    def self.call(...) = new(...).call

    def initialize(pull_request:, actor:, comment_id:, environment:, results:, unrun_capabilities: [], client: nil)
      @pull_request = pull_request
      @actor = actor
      @comment_id = comment_id
      @environment = environment.to_s.strip
      @results = results.to_s.strip
      @unrun_capabilities = Array(unrun_capabilities).map { |value| value.to_s.strip }.reject(&:blank?)
      @client = client
    end

    def call
      authorize!
      validate!
      pull_request.with_lock do
        comment = report_comment
        revision = current_revision
        event = existing_event(comment, revision)
        return Result.new(event:, created: false) if event

        Result.new(event: record(comment, revision), created: true)
      end
    end

    private

    attr_reader :actor, :comment_id, :environment, :pull_request, :results, :unrun_capabilities

    def authorize!
      raise Pundit::NotAuthorizedError unless ProjectPolicy.new(actor, pull_request.project).manage_issues?
    end

    def validate!
      raise ArgumentError, "A pull request is required" unless pull_request.is_pull_request?
      raise ArgumentError, "comment_id is required" unless comment_id.present?
      raise ArgumentError, "environment is required" if environment.blank?
      raise ArgumentError, "results are required" if results.blank?
    end

    def report_comment
      comment = client.issue_comments(project.full_name, pull_request.github_number).find { |entry| entry.id.to_s == comment_id.to_s }
      raise ArgumentError, "Comment was not found on this pull request" unless comment
      raise ArgumentError, "Comment author is not trusted" unless project.trusted_github_user?(comment.user&.login)
      raise ArgumentError, "Paid-generated status comments cannot be recorded as operator reports" if Activities::CompleteExistingPrRunActivity.agent_update_comment?(comment.body)

      comment
    end

    def current_revision
      client.pull_request(project.full_name, pull_request.github_number).head.sha
    end

    def existing_event(comment, revision)
      account.account_activity_events.where(action: ACTION, subject: pull_request)
        .find_by("metadata ->> 'report_identity' = ?", report_identity(comment, revision))
    end

    def record(comment, revision)
      Audit::RecordEvent.call(
        action: ACTION,
        actor:,
        subject: pull_request,
        metadata: {
          project_id: project.id,
          pull_request_number: pull_request.github_number,
          revision: revision,
          comment_id: comment.id.to_s,
          comment_url: comment.html_url.to_s,
          comment_author: comment.user.login,
          comment_body_digest: comment_body_digest(comment),
          report_identity: report_identity(comment, revision),
          environment: environment,
          results: results,
          unrun_capabilities: unrun_capabilities
        }
      )
    end

    def report_identity(comment, revision)
      [ pull_request.id, comment.id, comment_body_digest(comment), revision ].join(":")
    end

    def comment_body_digest(comment)
      Digest::SHA256.hexdigest(comment.body.to_s)
    end

    def account = project.account
    def client = @client || project.client
    def project = pull_request.project
  end
end
