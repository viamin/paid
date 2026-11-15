# frozen_string_literal: true

require "rails_helper"

# @spec AGENT-RETRY-017 EAGER-QUEUE-018
RSpec.describe AgentRuns::AutoPickCreatePrRetryPolicy do
  subject(:policy) { described_class.new }

  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, paid_state: "failed", github_state: "open") }

  it "leaves a recoverable rate-limited run with its in-place owner" do
    run = create(:agent_run, :rate_limited, :automatic, project: project, issue: issue,
      goal: "create_pr", auto_pick: true, rate_limited_until: 5.minutes.from_now)

    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :rate_limit_recovery_owned)
  end

  it "uses the issue failure streak as the retry attempt number" do
    create(:agent_run, :failed, :automatic, project: project, issue: issue, goal: "create_pr", auto_pick: true)
    run = create(:agent_run, :failed, :automatic, project: project, issue: issue, goal: "create_pr", auto_pick: true)

    expect(policy.assess(run)).to have_attributes(eligible?: true, attempt: 2)
  end
end
