# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260819042625_release_escalation_set_auto_continue_pause")

RSpec.describe ReleaseEscalationSetAutoContinuePause, :aggregate_failures do
  let(:migration) { described_class.new }

  # @spec PR-ESCALATION-018
  it "releases the pause on open escalated pull requests" do
    escalated = create(:issue, :pull_request,
      pr_review_phase: "escalated",
      github_state: "open",
      auto_continue_paused: true)

    migration.up

    expect(escalated.reload.auto_continue_paused).to be(false)
    expect(escalated.pr_review_phase).to eq("escalated")
  end

  # @spec PR-ESCALATION-018
  it "leaves the operator's pause untouched on pull requests that are not escalated" do
    operator_paused = create(:issue, :pull_request,
      pr_review_phase: "ready",
      github_state: "open",
      auto_continue_paused: true)
    draft_paused = create(:issue, :pull_request,
      pr_review_phase: "draft",
      github_state: "open",
      auto_continue_paused: true)

    migration.up

    expect(operator_paused.reload.auto_continue_paused).to be(true)
    expect(draft_paused.reload.auto_continue_paused).to be(true)
  end

  # @spec PR-ESCALATION-018
  it "leaves closed escalated pull requests alone" do
    closed = create(:issue, :pull_request,
      pr_review_phase: "escalated",
      github_state: "closed",
      auto_continue_paused: true)

    migration.up

    expect(closed.reload.auto_continue_paused).to be(true)
  end
end
