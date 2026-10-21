# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::UpdateOutcomes do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  # @spec RUN-OBSTACLE-005
  it "reports insufficient evidence until the post-correction exposure is comparable" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account, patterns: [])

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 3,
      post_remediation_exposure_count: 3,
      outcome: "insufficient_evidence"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "compares recurrence only after equivalent exposure and records an observed improvement" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create(:agent_run, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)
    create_list(:agent_run, 4, :completed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account, patterns: [])

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 1,
      post_remediation_exposure_count: 5,
      outcome: "improved"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "records an ineffective correction as unchanged once exposure is comparable" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)
    create_list(:agent_run, 2, :completed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account, patterns: [])

    expect(decision.reload.outcome).to eq("unchanged")
  end
end
