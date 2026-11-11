# frozen_string_literal: true

module TechnicalPrerequisites
  # Resolves whether a mixed criterion's human authorization occurrence
  # currently has sufficient operator evidence. A criterion with no matching
  # authorization occurrence was never gated behind a human step, so it is
  # reported granted — this never widens access, it only recognizes a
  # criterion that was purely agent-owned to begin with.
  # @spec PARTIAL-CLOSEOUT-048
  class Authorization
    def self.granted?(...) = new(...).granted?

    def initialize(issue:, criterion:)
      @issue = issue
      @criterion = criterion
    end

    def granted?
      return true if issue.nil?

      occurrence = authorization_occurrence
      return true unless occurrence

      current_sufficient_submission?(occurrence)
    end

    private

    attr_reader :issue, :criterion

    def notification
      @notification ||= Notification.find_by(
        account: issue.project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE
      )
    end

    def authorization_occurrence
      return unless notification

      PartialCloseouts::PrerequisiteOccurrences.for(notification).find do |occurrence|
        occurrence["criterion"] == criterion && occurrence["workflow"] == AUTHORIZATION_WORKFLOW
      end
    end

    def current_sufficient_submission?(occurrence)
      source_revision = occurrence["source_revision"]
      return false if source_revision.present? && source_revision != PartialCloseouts::Assessment.source_revision_for(issue)

      Array(notification.metadata["evidence_submissions"]).reverse.any? do |submission|
        submission["prerequisite_identity"] == occurrence["identity"] &&
          submission["source_revision"] == source_revision && submission["outcome"] == "sufficient"
      end
    end
  end
end
