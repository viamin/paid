# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-009 @spec CONFIDENCE-DELIVERY-011 @spec CONFIDENCE-DELIVERY-012
RSpec.describe FeatureIntents::CompleteForwardWork do
  let(:project) { create(:project) }
  let(:feature_intent) { create(:feature_intent, project:) }
  let(:completion_issue) { create(:issue, project:, github_number: 700, body: "Completion") }
  let(:implementation_issue) { create(:issue, project:, github_number: 701, body: "Implementation") }
  let(:client) { instance_double(GithubClient) }
  let(:remote_bodies) { { 700 => "Completion", 701 => "Implementation" } }
  let(:remote_issue_class) { Data.define(:body, :state) }
  let(:created_issue_class) { Data.define(:id, :number, :title, :body, :state, :labels, :user, :created_at, :updated_at, :html_url) }

  before do
    FeatureIntentIssue.create!(feature_intent:, issue: completion_issue)
    FeatureIntentIssue.create!(feature_intent:, issue: implementation_issue)
    allow(client).to receive(:issue) do |_repo, number|
      remote_issue_class.new(body: remote_bodies.fetch(number), state: "open")
    end
    allow(client).to receive(:update_issue) do |_repo, number, body: nil, **_options|
      remote_bodies[number] = body if body
    end
  end

  it "updates an unstarted issue and read-backs its completion dependency" do
    result = described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "a" * 64, finding: { summary: "Retain the discarded draft." }
    )

    expect(result).to be_success
    expect(result.item.status).to eq("applied")
    expect(implementation_issue.reload.body).to include("Retain the discarded draft.")
    expect(remote_bodies.fetch(700)).to include("Depends on #701")
    expect(completion_issue.reload.dependencies).to include(implementation_issue)
  end

  it "creates forward work instead of changing an issue with a rate-limited run" do
    create(:agent_run, :rate_limited, project:, issue: implementation_issue)
    allow(client).to receive_messages(
      search_issues: Data.define(:items).new([]),
      create_issue: created_issue_class.new(702, 702, "Follow up", "Forward work", "open", [], nil, Time.current, Time.current, nil)
    )

    result = described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "b" * 64, finding: { summary: "Retain the parked run's scope." }
    )

    expect(result).to be_success
    expect(implementation_issue.reload.body).not_to include("Retain the parked run's scope.")
    expect(result.item.follow_up_issue.github_number).to eq(702)
    expect(remote_bodies.fetch(700)).to include("Depends on #702")
  end

  it "keeps a remote dependency write pending when its read-back fails" do
    allow(client).to receive(:issue).with(project.full_name, 700).and_return(
      remote_issue_class.new(body: "Completion", state: "open")
    )

    expect {
      described_class.reconcile(feature_intent:, completion_issue:, client:)
    }.to raise_error(GithubClient::Error, /read back/)

    expect(feature_intent.feature_intent_completion.reload.pending_operations).to include("dependency:#{implementation_issue.id}")
  end

  it "refuses completion until every dependency and acceptance/release check is satisfied" do
    result = described_class.complete(
      feature_intent:, completion_issue:, client:, acceptance_verified: true,
      isolation: { feasible: false, actual: "not isolated" }, release_authorized: true
    )

    expect(result.code).to eq(:open_dependencies)
    implementation_issue.update!(github_state: "closed")
    result = described_class.complete(
      feature_intent:, completion_issue:, client:, acceptance_verified: true,
      isolation: { feasible: false, actual: "not isolated" }, release_authorized: false
    )

    expect(result.code).to eq(:release_unauthorized)
  end
end
