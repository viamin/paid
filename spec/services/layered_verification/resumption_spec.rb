# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Resumption do
  def approved_obligation(project)
    obligation = create(:layered_verification_obligation, project:)
    obligation.record_approval!(revision: "intent-v1", approval_reference: "docs/intent/payment.md", persisted: true)
    obligation
  end

  def interrupted_run(project:, user:, obligation:, goal:, status:)
    dependencies = { "environment" => { "immutable" => true, "digest" => "sha256:runtime" },
      "producer_versions" => { "paid" => "1.2.3" },
      "tool_versions" => { "tlc_runtime_image_digest" => "sha256:runtime" } }
    create(:agent_run, project:, initiating_user: user, goal:, status:,
      originating_audit_run: (originating_audit(project:, user:) if goal == "layered_verification_repair"),
      external_metadata: { "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "code-v1",
        "budget" => { "max_minutes" => 5 }, "dependencies" => dependencies } })
  end

  def originating_audit(project:, user:)
    create(:agent_run, project:, initiating_user: user, goal: "layered_verification_audit", status: "completed")
  end

  # @spec LAYERED-VERIFY-020
  it "admits an interrupted audit only after current authorization, approval, budget, and freshness checks" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = approved_obligation(project)
    run = interrupted_run(project:, user:, obligation:, goal: "layered_verification_audit", status: "cancelled")
    result = create(:layered_verification_check_result, obligation:, agent_run: run, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v1",
      "dependencies" => run.external_metadata.dig("layered_verification", "dependencies")
    })
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    decision = described_class.call(agent_run: run, user:)

    expect(decision).to be_admitted
    expect(decision.reusable_result_ids).to eq([ result.id ])
    expect(decision.replay_repair_mutation?).to be(false)
  end

  # @spec LAYERED-VERIFY-020
  it "rejects a budget-exhausted audit when its elapsed time consumed the allowance" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = approved_obligation(project)
    run = interrupted_run(project:, user:, obligation:, goal: "layered_verification_audit", status: "token_budget_exceeded")
    run.update!(started_at: 5.minutes.ago, completed_at: Time.current)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    expect { described_class.call(agent_run: run, user:) }
      .to raise_error(LayeredVerification::Audits::Request::InvalidBudgetError, /no budget remains/)
  end

  # @spec LAYERED-VERIFY-020
  it "bounds a resumed audit to the remaining allowance" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = approved_obligation(project)
    run = interrupted_run(project:, user:, obligation:, goal: "layered_verification_audit", status: "failed")
    now = Time.current
    run.update!(started_at: now - 2.minutes, completed_at: now)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    expect(described_class.call(agent_run: run, user:).remaining_budget).to eq("max_minutes" => 3)
  end

  # @spec LAYERED-VERIFY-020
  it "admits an interrupted repair run, which the spec names alongside audits" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = approved_obligation(project)
    run = interrupted_run(project:, user:, obligation:, goal: "layered_verification_repair", status: "failed")
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    decision = described_class.call(agent_run: run, user:)

    expect(decision).to be_admitted
    expect(decision.replay_repair_mutation?).to be(false)
  end

  it "rejects a non-interrupted (completed) run" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = approved_obligation(project)
    run = interrupted_run(project:, user:, obligation:, goal: "layered_verification_audit", status: "completed")
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    expect { described_class.call(agent_run: run, user:) }
      .to raise_error(ArgumentError, /only interrupted layered-verification runs can resume/)
  end
end
