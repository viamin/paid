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
        selections: { obligation.id => { "selected_checks" => [ "implementation_conformance" ],
          "fit" => "Check the implementation mapping", "exclusions" => [ "No formal model is declared" ] } }
      )
    }.to have_enqueued_job(ProcessRunQueueJob)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, status: "queued")
    expect(run).to have_attributes(base_commit_sha: "resolved-sha")
    expect(run.effective_prompt).to include("Layered-verification audit", "resolved-sha", "implementation_conformance")
    expect(run.external_metadata.dig("layered_verification", "budget", "max_minutes")).to eq(15)
    expect(run.external_metadata.dig("layered_verification", "input_revisions")).to eq(obligation.id.to_s => obligation.external_revision)
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
          budget: { "max_minutes" => max_minutes }, selections: { obligation.id => { "selected_checks" => [ "implementation_conformance" ] } })
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
      selections: { obligation.id => { "selected_checks" => [ "implementation_conformance" ],
        "fit" => "Check the implementation mapping", "exclusions" => [ "No formal model is declared" ] } }
    )

    expect(run.base_commit_sha).to eq("resolved-sha")
  end

  # @spec LAYERED-VERIFY-027
  it "rejects a second active audit for the same scope and revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).and_return(OpenStruct.new(sha: "resolved-sha"))
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "queued",
      base_commit_sha: "resolved-sha",
      external_metadata: { "layered_verification" => { "obligation_ids" => [ obligation.id ] } })

    expect {
      described_class.call(project:, user:, obligation_ids: [ obligation.id ], target_revision: "main",
        budget: { "max_minutes" => 15 },
        selections: { obligation.id => { "selected_checks" => [ "implementation_conformance" ],
          "fit" => "Check the implementation mapping", "exclusions" => [ "No formal model is declared" ] } })
    }.to raise_error(described_class::DuplicateAuditError, "an audit for this scope and revision is already active")
  end

  # @spec LAYERED-VERIFY-027
  it "rejects an active audit whose scope overlaps at the same revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    first, shared, other = create_list(:layered_verification_obligation, 3, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).and_return(OpenStruct.new(sha: "resolved-sha"))
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "queued",
      base_commit_sha: "resolved-sha",
      external_metadata: { "layered_verification" => { "obligation_ids" => [ first.id, shared.id ] } })

    expect {
      described_class.call(project:, user:, obligation_ids: [ shared.id, other.id ], target_revision: "main",
        budget: { "max_minutes" => 15 },
        selections: [ shared, other ].to_h { |obligation| [ obligation.id,
          { "selected_checks" => [ "implementation_conformance" ], "fit" => "Check the implementation mapping",
            "exclusions" => [ "No formal model is declared" ] } ] })
    }.to raise_error(described_class::DuplicateAuditError, "an audit for this scope and revision is already active")
  end

  it "admits an audit whose scope differs from the active one, even at the same revision" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    active, other = create_list(:layered_verification_obligation, 2, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(project.client).to receive(:commit).and_return(OpenStruct.new(sha: "resolved-sha"))
    create(:agent_run, issue: nil, project:, goal: "layered_verification_audit", status: "queued",
      base_commit_sha: "resolved-sha",
      external_metadata: { "layered_verification" => { "obligation_ids" => [ active.id ] } })

    expect {
      described_class.call(project:, user:, obligation_ids: [ other.id ], target_revision: "main",
        budget: { "max_minutes" => 15 },
        selections: { other.id => { "selected_checks" => [ "implementation_conformance" ],
          "fit" => "Check the implementation mapping", "exclusions" => [ "No formal model is declared" ] } })
    }.to change(AgentRun, :count).by(1)
  end
end
