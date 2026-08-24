# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "alpha") }

  describe ".call" do
    it "returns clarifying-question and open plan-review entries in one queue" do
      issue = create_needs_input_issue(project: project, question: "What should happen next?")
      review = create_plan_review(project: project, workflow_id: "planning-workflow-1")

      entries = described_class.call(user: user)

      expect(entries.map(&:kind)).to include("clarifying_questions", "plan_review")
      expect(entries.find { |entry| entry.record == issue }).to have_attributes(
        issue: issue,
        questions: [ "What should happen next?" ]
      )
      expect(entries.find { |entry| entry.record == review }).to have_attributes(
        issue: review.issue,
        tasks: [ { "title" => "Task 1", "description" => "Do the thing" } ]
      )
    end

    it "excludes plan reviews that are no longer open" do
      review_issue = create(:issue, project: project)
      create_plan_review(project: project, issue: review_issue, workflow_id: "planning-workflow-1", plan_data: {})
      create(
        :decomposition_decision,
        project: project,
        issue: review_issue,
        workflow_id: "planning-workflow-1",
        decision_key: "planning-workflow-1:plan_review:approved",
        decision_type: "planning_outcome",
        outcome: "plan_review_approved"
      )

      entries = described_class.call(user: user, kind: "plan_review")

      expect(entries).to be_empty
    end

    it "applies the explicit project scope to both entry kinds" do
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "beta")
      create(:issue, :needs_input, project: project, needs_input_questions: [ "Scoped question?" ])
      create(:issue, :needs_input, project: other_project, needs_input_questions: [ "Other question?" ])

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:project).uniq).to eq([ project ])
    end
  end

  def create_needs_input_issue(project:, question:)
    create(:issue, :needs_input, project: project, body: "Need help", needs_input_questions: [ question ])
  end

  def create_plan_review(project:, workflow_id:, issue: create(:issue, project: project), plan_data: nil)
    create(
      :decomposition_decision,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      decision_key: "#{workflow_id}:plan_review:pending",
      decision_type: "planning_outcome",
      outcome: "plan_pending_review",
      plan_data: plan_data || { "tasks" => [ { "title" => "Task 1", "description" => "Do the thing" } ] }
    )
  end
end
