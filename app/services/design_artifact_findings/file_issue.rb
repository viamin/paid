# frozen_string_literal: true

module DesignArtifactFindings
  # Files a new GitHub issue from a traceability gap so operators can
  # establish ownership when no existing issue covers the artifact. The
  # finding is then recorded as `assigned` against the freshly created
  # issue via `Resolve`, keeping the pending-until-verified lifecycle
  # consistent with the existing linked-work path.
  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  class FileIssue
    IDEMPOTENCY_MARKER = "paid-traceability-finding"
    MAX_TITLE_LENGTH = 255
    MAX_BODY_LENGTH = 65_535

    def self.call(...) = new(...).call

    def initialize(finding:, user:, title:, body:, revision:)
      @finding = finding
      @user = user
      @title = title.to_s.strip
      @body = body.to_s.strip
      @revision = revision.to_s
    end

    def call
      validate!
      cached_project = project
      finding.with_lock do
        verify_revision!
        issue = reuse_assigned_issue(cached_project) || create_and_persist_issue!(cached_project)
        Resolve.call(finding:, user:, state: "assigned", reason: idempotent_reason_for(issue),
          revision: finding.revision, issue:)
        issue
      end
    end

    private

    attr_reader :finding, :user, :title, :body, :revision

    def validate!
      raise ArgumentError, "a title is required" if title.blank?
      raise ArgumentError, "a body is required" if body.blank?
      raise ArgumentError, "finding does not belong to a project" if finding.project_id.blank?
    end

    def verify_revision!
      return if finding.revision == revision

      raise ArgumentError, "finding changed; reload before filing"
    end

    # Reuse the issue that an earlier file-issue call already linked to this
    # finding so a duplicate submit (operator retry, browser back, network
    # re-send) does not open a second GitHub issue for the same gap.
    def reuse_assigned_issue(project_record)
      existing = finding.resolution_issue
      return existing if existing && existing.project_id == project_record.id && existing.github_state == "open"

      nil
    end

    def create_and_persist_issue!(project_record)
      remote = project_record.client.create_issue(
        project_record.full_name,
        title: title.truncate(MAX_TITLE_LENGTH),
        body: body_with_marker,
        labels: file_issue_labels(project_record)
      )
      raise GithubClient::Error, "GitHub did not return a created issue" if remote.nil?

      Issues::UpsertFromGithub.call(project: project_record, github_issue: remote)
    end

    def body_with_marker
      [ body, marker ].reject(&:blank?).join("\n\n")
    end

    def marker
      "<!-- #{IDEMPOTENCY_MARKER}:#{finding.id}:#{revision} -->"
    end

    def idempotent_reason_for(issue)
      "Filed as ##{issue.github_number} to own the document repair."
    end

    def file_issue_labels(project_record)
      labels = []
      labels << project_record.automation_label_name if project_record.automation_on_label_enabled?
      labels << project_record.generated_label_name if project_record.auto_add_labels_enabled?
      labels
    end

    def project
      @project ||= finding.project
    end
  end
end
