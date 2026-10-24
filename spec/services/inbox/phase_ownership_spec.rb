# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec INBOX-PHASE-RELEVANCE-001 @spec AUTOMATION-PHASES-017
RSpec.describe Inbox::PhaseOwnership do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before { allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: [])) }

  def entry_for(issue, scope: nil)
    scopes = scope ? [ scope ] : Inbox::Queue::SCOPES
    scopes.each do |candidate_scope|
      entry = Inbox::Queue.call(user:, project:, scope: candidate_scope).find { |item| item.issue&.id == issue.id }
      return entry if entry
    end
    nil
  end

  def questions_body
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end

  describe "production-time assignment" do
    it "records issue preparation ownership when an enhancement run parks an issue for input" do
      FeatureFlags.enable!(:automation_phases, project:)
      issue = create(:issue, project:, github_state: "open", needs_input_questions: [ "Which behavior?" ])

      issue.update!(paid_state: "needs_input")

      ownership = InboxRequestOwnership.find_by(request_key: "clarifying_questions:#{issue.id}")
      expect(ownership).to have_attributes(
        responsible_phase: "issue_preparation",
        classification_state: "classified",
        origin_kind: "issue",
        origin_id: issue.id
      )
    end

    it "keeps the recorded ownership when the request is rebuilt" do
      FeatureFlags.enable!(:automation_phases, project:)
      issue = create(:issue, project:, github_state: "open", needs_input_questions: [ "Which behavior?" ])
      issue.update!(paid_state: "needs_input")

      expect(described_class.for_entry(entry_for(issue)).responsible_phase).to eq("issue_preparation")
    end

    it "records a coding manual-review request in the coding phase" do
      FeatureFlags.enable!(:automation_phases, project:)
      issue = create(:issue, project:, github_state: "open")
      create(:agent_run, project:, issue:, goal: "create_pr", status: "completed")

      issue.update!(paid_state: "manual_review", manual_review_reason: "CI repair required")

      expect(InboxRequestOwnership.find_by(request_key: "manual_review:#{issue.id}").responsible_phase).to eq("coding")
    end

    it "does not write ownership while the rollout flag is off" do
      issue = create(:issue, project:, github_state: "open", needs_input_questions: [ "Which behavior?" ])

      issue.update!(paid_state: "needs_input")

      expect(InboxRequestOwnership.count).to eq(0)
    end
  end

  describe "legacy classification from evidence" do
    it "uses the entry kind when an anonymous record type has no class name" do
      record = Class.new.new
      entry = Inbox::Queue::Entry.new(
        id: "action_required:5", kind: Inbox::Queue::ACTION_REQUIRED_KIND, project:, record:
      )

      expect(described_class.for_entry(entry)).to have_attributes(
        classification_state: "classified",
        origin_kind: Inbox::Queue::ACTION_REQUIRED_KIND
      )
    end

    it "classifies an enhancement clarification request as issue preparation" do
      issue = create(:issue, :needs_input, project:, github_state: "open", body: questions_body)

      expect(described_class.for_entry(entry_for(issue)).responsible_phase).to eq("issue_preparation")
    end

    it "classifies a coding blocker as coding" do
      issue = create(:issue, project:, github_state: "open", paid_state: "manual_review",
        manual_review_reason: "CI repair required")

      expect(described_class.for_entry(entry_for(issue)).responsible_phase).to eq("coding")
    end

    it "classifies an enhancement-exhausted manual review as issue preparation" do
      issue = create(:issue, project:, github_state: "open", paid_state: "manual_review",
        manual_review_reason: "Enhancement rounds exhausted")
      create(:agent_run, project:, issue:, goal: "enhance_issue", status: "completed")

      expect(described_class.for_entry(entry_for(issue)).responsible_phase).to eq("issue_preparation")
    end

    it "marks a merge approval as merge" do
      entry = Inbox::Queue::Entry.new(
        id: "merge_approval:5", kind: Inbox::Queue::MERGE_APPROVAL_KIND, project:, record: OpenStruct.new(id: 5)
      )

      expect(described_class.for_entry(entry).responsible_phase).to eq("merge")
    end

    it "marks a blocking operational notification as operations" do
      entry = Inbox::Queue::Entry.new(
        id: "action_required:5", kind: Inbox::Queue::ACTION_REQUIRED_KIND, project:,
        record: Notification.new(id: 5, subject: create(:agent_run, project:))
      )

      expect(described_class.for_entry(entry).responsible_phase).to eq("operations")
    end

    it "leaves ownership unknown instead of guessing when evidence does not resolve a phase" do
      entry = Inbox::Queue::Entry.new(
        id: "some_future_lane:5", kind: "some_future_lane", project:, record: OpenStruct.new(id: 5)
      )

      ownership = described_class.for_entry(entry)

      expect(ownership).to be_unknown
      expect(ownership).not_to be_phase_owned
    end
  end

  describe "platform requests" do
    it "treats a request with no project as a platform request with no phase" do
      entry = Inbox::Queue::Entry.new(
        id: "action_required:1", kind: Inbox::Queue::ACTION_REQUIRED_KIND,
        project:, record: Notification.new(id: 1)
      )

      ownership = described_class.for_entry(entry)

      expect(ownership.classification_state).to eq("platform")
      expect(ownership.responsible_phase).to be_nil
    end

    # @spec INBOX-PHASE-RELEVANCE-001 @spec OPERATOR-INBOX-019
    it "classifies unverifiable coverage as a platform request so a disabled coding phase cannot hide it" do
      finding = create(:design_artifact_finding, project:, account: project.account, state: "unverifiable")
      entry = Inbox::Queue::Entry.new(
        id: "#{Inbox::Queue::TRACEABILITY_GAP_KIND}:#{finding.id}",
        kind: Inbox::Queue::TRACEABILITY_GAP_KIND,
        project:, record: finding
      )

      ownership = described_class.for_entry(entry)

      expect(ownership.classification_state).to eq("platform")
      expect(ownership.responsible_phase).to be_nil
      expect(ownership).not_to be_phase_owned
    end

    # @spec OPERATOR-INBOX-019
    it "keeps actionable traceability gaps owned by the coding phase" do
      finding = create(:design_artifact_finding, project:, account: project.account)
      entry = Inbox::Queue::Entry.new(
        id: "#{Inbox::Queue::TRACEABILITY_GAP_KIND}:#{finding.id}",
        kind: Inbox::Queue::TRACEABILITY_GAP_KIND,
        project:, record: finding
      )

      expect(described_class.for_entry(entry).responsible_phase).to eq("coding")
    end
  end
end
