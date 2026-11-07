# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentCheckpoint::Gate do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:gate) { described_class.call(project: project, issue: issue) }

  before do
    issue.update!(needs_input_questions: [ "What should the default window be?", "Who owns the runbook?" ])
  end

  def settle_checkpoint(checkpoint:, disposition: "settled", answers: nil)
    answers = [] if disposition == "rejected"
    answers ||= checkpoint.question_groups.map { |group| { "group_key" => group.fetch("key"), "answer" => "7 days." } }
    ProjectDelegation::IntentCheckpoint::Settle.call(checkpoint: checkpoint, actor: user,
      disposition: disposition, answers: answers)
  end

  it "reports no material questions when nothing is known" do
    issue.update!(needs_input_questions: nil)

    expect(gate.state).to eq(:no_material_questions)
    expect(gate).to be_permitted
    expect(issue.delegation_intent_checkpoints).to be_empty
  end

  it "opens and blocks on the checkpoint when material questions are unsettled" do
    expect(gate.state).to eq(:pending)
    expect(gate).to be_blocked
    expect(gate.checkpoint).to be_pending
    expect(Notification.find_by(account: account, subject: issue,
      source: ProjectDelegation::IntentCheckpoint::Open::NOTIFICATION_SOURCE)).to be_present
  end

  it "blocks while the settlement was a rejection" do
    checkpoint = ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue)
    settle_checkpoint(checkpoint: checkpoint, disposition: "rejected", answers: nil)

    expect(gate.state).to eq(:rejected)
    expect(gate).to be_blocked
  end

  describe "a current settlement" do
    it "permits and does not re-ask in a later phase" do
      checkpoint = ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue)
      settle_checkpoint(checkpoint: checkpoint)

      result = gate

      expect(result.state).to eq(:permitted)
      expect(result).to be_permitted
      expect(result.settlement.answer_for(checkpoint.question_groups.first.fetch("key"))).to eq("7 days.")
      expect(Notification.where(account: account, subject: issue,
        source: described_class::REDECISION_SOURCE)).to be_empty
    end
  end

  describe "new evidence moving a bound revision" do
    it "routes exactly one focused re-decision naming only the changed questions" do
      checkpoint = ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue)
      settle_checkpoint(checkpoint: checkpoint)

      issue.update!(needs_input_questions: [ "What should the default window be?", "Who owns the runbook?", "What is the retention policy?" ])
      result = gate

      expect(result.state).to eq(:revision_delta)
      expect(result.affected_groups.map { |group| group["question"] }).to contain_exactly("What is the retention policy?")

      notification = Notification.find_by(account: account, subject: issue, source: described_class::REDECISION_SOURCE)
      expect(notification).to be_blocking
      expect(notification.metadata).to include(
        "settlement_id" => result.settlement.id,
        "bound_design_revision" => checkpoint.design_revision,
        "current_design_revision" => result.current_revisions.fetch("design_revision"),
        "affected_groups" => contain_exactly(hash_including("question" => "What is the retention policy?")),
        "recommended_action" => anything
      )

      expect(described_class.call(project: project, issue: issue).notification.id).to eq(notification.id)
    end

    it "does not reopen unrelated settled questions on a cosmetic edit" do
      checkpoint = ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue)
      settle_checkpoint(checkpoint: checkpoint)

      issue.update!(needs_input_questions: [ "What should the default window be?", "Who owns the runbook?  " ])

      expect(gate.state).to eq(:permitted)
      expect(Notification.where(account: account, subject: issue, source: described_class::REDECISION_SOURCE)).to be_empty
    end

    it "stops gating when no material question remains" do
      checkpoint = ProjectDelegation::IntentCheckpoint::Open.call(project: project, issue: issue)
      settle_checkpoint(checkpoint: checkpoint)

      issue.update!(needs_input_questions: nil)

      expect(gate.state).to eq(:no_material_questions)
      expect(gate).to be_permitted
    end
  end

  describe ".boundary_result" do
    it "shapes a blocked delegated-work result with the gate reason" do
      result = described_class.boundary_result(gate, :dequeue)

      expect(result).to be_blocked
      expect(result.boundary).to eq(:dequeue)
      expect(result.reasons).to eq([ "intent_checkpoint_pending" ])
    end
  end
end
