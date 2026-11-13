# frozen_string_literal: true

module TechnicalPrerequisites
  # Finds the independently validated human authorization paired with a
  # technical criterion. A technical result cannot create or imply this record.
  # @spec PARTIAL-CLOSEOUT-050
  class Authorization
    def self.granted?(...) = new(...).granted?

    def initialize(issue:, identifier:)
      @issue = issue
      @identifier = identifier.to_s
    end

    def granted?
      return true if identifier.blank?

      matching_occurrences.any? { |notification, occurrence| sufficient?(notification, occurrence) }
    end

    private

    attr_reader :identifier, :issue

    def matching_occurrences
      notifications.flat_map do |notification|
        PartialCloseouts::PrerequisiteOccurrences.for(notification).filter_map do |occurrence|
          [ notification, occurrence ] if occurrence["technical_authorization_id"] == identifier &&
            occurrence["source_issue_number"].to_i == issue.github_number
        end
      end
    end

    def notifications
      Notification.where(account: issue.project.account, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE)
        .where(subject_type: "Issue", subjects: { project_id: issue.project_id }).joins("INNER JOIN issues subjects ON subjects.id = notifications.subject_id")
    end

    def sufficient?(notification, occurrence)
      Array(notification.metadata["evidence_submissions"]).reverse.any? do |submission|
        submission["prerequisite_identity"] == occurrence["identity"] &&
          submission["outcome"] == "sufficient" && current?(notification, occurrence, submission)
      end
    end

    def current?(notification, occurrence, submission)
      revision = occurrence["source_revision"]
      revision.blank? || (submission["source_revision"] == revision &&
        PartialCloseouts::PrerequisiteOccurrences.current_source_revision(notification, occurrence) == revision)
    end
  end
end
