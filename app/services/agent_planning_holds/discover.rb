# frozen_string_literal: true

module AgentPlanningHolds
  # Makes legacy labels visible to reconciliation without treating their
  # presence, or the identity that may have added them, as Paid ownership.
  # @spec CONFIDENCE-DELIVERY-018
  class Discover
    LABEL = FeatureIntents::ReleaseIssue::PLANNING_LABEL

    def self.call(...) = new(...).call

    def initialize(project:)
      @project = project
    end

    def call
      planning_labeled_issues.find_each { |issue| create_review_hold(issue) }
    end

    private

    attr_reader :project

    def planning_labeled_issues
      project.issues
        .where("labels @> ?::jsonb", [ LABEL ].to_json)
        .where.not(id: recorded_issue_ids)
    end

    def recorded_issue_ids
      AgentPlanningHold.where(project:, label: LABEL).where.not(issue_id: nil).select(:issue_id)
    end

    def create_review_hold(issue)
      hold = AgentPlanningHold.create_or_find_by!(project:, remote_issue_number: issue.github_number, label: LABEL) do |record|
        record.account = project.account
        record.issue = issue
      end
      hold.update!(issue:) if hold.issue_id != issue.id
      RequestReview.call(hold:) unless hold.paid_owned?
    end
  end
end
