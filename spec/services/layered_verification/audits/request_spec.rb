# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe LayeredVerification::Audits::Request do
  include ActiveJob::TestHelper

  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-013 LAYERED-VERIFY-024
  it "queues an issue-less audit with an executable audit prompt" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).with(project.full_name, "abc123")
      .and_return(OpenStruct.new(sha: "resolved-sha"))

    run = nil
    expect {
      run = described_class.call(
        project:, user:, obligation_ids: [ obligation.id ], target_revision: "abc123",
        budget: { "max_minutes" => 15 },
        selections: { obligation.id => { "selected_checks" => [ "spec_to_code" ] } }
      )
    }.to have_enqueued_job(ProcessRunQueueJob)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, status: "queued")
    expect(run).to have_attributes(base_commit_sha: "resolved-sha")
    expect(run).to have_attributes(initiating_user: user, trigger_type: "manual")
    expect(run.effective_prompt).to include("Layered-verification audit", "resolved-sha", "spec_to_code")
    expect(run.external_metadata.dig("layered_verification", "budget", "max_minutes")).to eq(15)
  end

  it "rejects non-numeric and out-of-range budgets" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).and_return(OpenStruct.new(sha: "resolved-sha"))

    [ nil, "fifteen", 0, 121 ].each do |max_minutes|
      expect {
        described_class.call(project:, user:, obligation_ids: [ obligation.id ], target_revision: "main",
          budget: { "max_minutes" => max_minutes }, selections: { obligation.id => { "selected_checks" => [ "spec_to_code" ] } })
      }.to raise_error(described_class::InvalidBudgetError, "budget must be between 1 and 120 minutes")
    end
  end

  # @spec LAYERED-VERIFY-010
  it "resolves branch names longer than a commit SHA" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    long_revision = "feature/#{"bounded-audit-" * 4}reports"
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).with(project.full_name, long_revision)
      .and_return(OpenStruct.new(sha: "resolved-sha"))

    run = described_class.call(
      project:, user:, obligation_ids: [ obligation.id ], target_revision: long_revision,
      budget: { "max_minutes" => 15 },
      selections: { obligation.id => { "selected_checks" => [ "spec_to_code" ] } }
    )

    expect(run.base_commit_sha).to eq("resolved-sha")
  end
end
