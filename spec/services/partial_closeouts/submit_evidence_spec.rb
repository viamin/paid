# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:actor) { create(:user, account: project.account) }
  let!(:run) do
    create(:agent_run, project:, issue:, reconciliation: {
      "status" => "awaiting_operator",
      "gaps" => { "0" => { "criterion" => "pilot", "kind" => "human", "next_step" => "Run pilot" } }
    })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records exact occurrence, revision, actor and a pending disposition for external evidence" do
    result = described_class.call(issue:, actor:, prerequisite_id: "#{run.id}:0", kind: "artifact",
      reference: "artifact-42", revision: "sha-1", explanation: "Signed pilot record.")

    expect(result).to be_success
    submission = run.reload.reconciliation.dig("gaps", "0", "evidence_submissions").last
    expect(submission).to include("kind" => "artifact", "reference" => "artifact-42", "revision" => "sha-1",
      "actor_id" => actor.id, "outcome" => "submitted")
    expect(submission.fetch("reasoning")).to include("acceptance audit")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not let a malformed link masquerade as accepted evidence" do
    result = described_class.call(issue:, actor:, prerequisite_id: "#{run.id}:0", kind: "link",
      reference: "javascript:alert(1)", revision: "v1", explanation: "Looks green")

    expect(result).to be_success
    expect(run.reload.reconciliation.dig("gaps", "0", "evidence_submissions").last.fetch("outcome")).to eq("unavailable")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "keeps a dismissed notification from releasing an unsatisfied human prerequisite" do
    notification = create(:notification, :error, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    notification.update!(dismissed_at: Time.current)

    source = Automation::Strategies::AutoPick::DefaultCandidateSource
    expect(source.send(:partial_closeout_prerequisite_block_issue_ids, project)).to include(issue.id)
  end
end
