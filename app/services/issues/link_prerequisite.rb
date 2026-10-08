# frozen_string_literal: true

module Issues
  # Links a prerequisite to a stalled partial-closeout issue from the human
  # Inbox pane: appends the project's dependency wording to the issue body on
  # GitHub (the same rewrite Reconcile#publish_parent_dependencies! performs)
  # and re-parses the local dependency records immediately, so the operator
  # sees the linkage without waiting for the next sync (#4189).
  # @spec PARTIAL-CLOSEOUT-016
  class LinkPrerequisite
    LOCAL_REF = /\A#?([1-9]\d*)\z/

    Result = Struct.new(:issue, :prerequisite_number, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, depends_on:)
      @issue = issue
      @actor = actor
      @depends_on = depends_on.to_s.strip
    end

    def call
      return failure(:invalid_ref, "Enter a prerequisite issue number like #41.") unless local_ref?
      return failure(:self_reference, "An issue cannot depend on itself.") if number == issue.github_number

      prerequisite = issue.project.issues.find_by(github_number: number)
      if prerequisite.nil?
        return failure(:unknown_issue,
          "Paid has no local record of ##{number} yet — run a project sync first, then link the prerequisite.")
      end
      if Issues::DetectCycle.call(from_issue: prerequisite, target_issue_id: issue.id)
        return failure(:cycle, "##{number} already depends on this issue — linking it here would create a dependency cycle.")
      end

      client = issue.project.client
      return failure(:github_unavailable, "GitHub access is not configured for this project.") unless client

      body = current_remote_body(client)
      updated_body = append_dependency_line(body)
      if updated_body != body
        client.update_issue(issue.project.full_name, issue.github_number, body: updated_body)
      end
      issue.update!(body: updated_body)
      Issues::ParseDependencies.call(issue: issue, body: updated_body, comments: trusted_comment_bodies(client))

      Audit::RecordEvent.call(
        action: "issue.prerequisite_linked",
        actor: actor,
        subject: issue,
        metadata: { prerequisite_number: number, prerequisite_issue_id: prerequisite.id, body_updated: updated_body != body }
      )

      Result.new(issue: issue, prerequisite_number: number)
    rescue GithubClient::Error => e
      failure(:github_error, "GitHub refused the prerequisite link: #{e.message}")
    end

    private

    attr_reader :actor, :depends_on, :issue

    def local_ref?
      depends_on.match?(LOCAL_REF)
    end

    def number
      depends_on[LOCAL_REF, 1].to_i
    end

    # Base the rewrite on the live GitHub body, not the local copy, so human
    # edits made since the last sync survive (same pattern as
    # PartialCloseouts::Reconcile#publish_parent_dependencies!).
    def current_remote_body(client)
      client.issue(issue.project.full_name, issue.github_number).body.to_s
    end

    def append_dependency_line(body)
      ProjectConventions::IssueDependencies.append_dependency_lines(
        project: issue.project, github_numbers: [ number ], body:
      )
    end

    # Preserve comment-declared dependencies through the immediate re-parse:
    # the parser replaces the local set with what the body + comments imply,
    # so re-derive the same comment baseline the sync path uses (trusted
    # authors, oldest-first).
    def trusted_comment_bodies(client)
      client.recent_issue_comments(issue.project.full_name, issue.github_number)
        .select { |comment| issue.project.trusted_github_user?(comment.user&.login) }
        .map { |comment| comment.body.to_s }
    end

    def failure(code, message) = Result.new(code: code, message: message)
  end
end
