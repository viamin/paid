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

  def record_recoverable_finding
    described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "r" * 64, finding: { summary: "Recover this remote write." }
    )
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

  it "preserves a human edit made after the affected issue was last synced" do
    remote_bodies[implementation_issue.github_number] = "Human release control"

    described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "c" * 64, finding: { summary: "Retain the human control." }
    )

    expect(remote_bodies.fetch(implementation_issue.github_number)).to include("Human release control")
    expect(implementation_issue.reload.body).to include("Human release control")
  end

  it "does not duplicate forward work when re-routing an interrupted write" do
    first = described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "e" * 64, finding: { summary: "Interrupted write." }
    )
    first.item.update!(status: "pending")

    described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "e" * 64, finding: { summary: "Interrupted write." }
    )

    body = remote_bodies.fetch(implementation_issue.github_number)
    expect(body.scan("## Forward work").count).to eq(1)
    expect(body.scan("Interrupted write.").count).to eq(1)
  end

  it "recovers an unstarted-issue write after its local transaction rolls back" do
    allow(client).to receive(:issue) do |_repo, number|
      body = number == completion_issue.github_number ? "Completion" : remote_bodies.fetch(number)
      remote_issue_class.new(body:, state: "open")
    end

    expect {
      ActiveRecord::Base.transaction(requires_new: true) do
        record_recoverable_finding
      end
    }.to raise_error(GithubClient::Error, /read back/)

    expect(FeatureIntentCompletion.where(feature_intent:)).to be_empty
    expect {
      record_recoverable_finding
    }.to raise_error(GithubClient::Error, /read back/)
    expect(remote_bodies.fetch(implementation_issue.github_number).scan("## Forward work").count).to eq(1)
    expect(remote_bodies.fetch(implementation_issue.github_number).scan("Recover this remote write.").count).to eq(1)
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

  it "does not mistake a longer dependency number for the required dependency" do # @spec CONFIDENCE-DELIVERY-011
    remote_bodies[completion_issue.github_number] = "Completion\n\n- Depends on #7012"
    allow(client).to receive(:update_issue) do |_repo, number, body: nil, **_options|
      remote_bodies[number] = body if body && number != completion_issue.github_number
    end

    expect {
      described_class.reconcile(feature_intent:, completion_issue:, client:)
    }.to raise_error(GithubClient::Error, /read back/)

    expect(completion_issue.dependencies).to be_empty
    expect(feature_intent.feature_intent_completion.reload.pending_operations).to include("dependency:#{implementation_issue.id}")
  end

  it "creates follow-up work for an affected pull request instead of editing its description" do # @spec CONFIDENCE-DELIVERY-008
    implementation_issue.update!(is_pull_request: true)
    allow(client).to receive_messages(
      search_issues: Data.define(:items).new([]),
      create_issue: created_issue_class.new(702, 702, "Follow up", "Forward work", "open", [], nil, Time.current, Time.current, nil)
    )

    result = described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "p" * 64, finding: { summary: "Follow up outside the active PR." }
    )

    expect(result.item.follow_up_issue.github_number).to eq(702)
    expect(remote_bodies.fetch(implementation_issue.github_number)).to eq("Implementation")
    expect(client).to have_received(:create_issue)
  end

  it "loads account dependency adjacency for the preflight and each persisted dependency" do # @spec CONFIDENCE-DELIVERY-011
    second_issue = create(:issue, project:, github_number: 702, body: "Second implementation")
    FeatureIntentIssue.create!(feature_intent:, issue: second_issue)
    remote_bodies[second_issue.github_number] = second_issue.body
    allow(IssueDependency).to receive(:account_adjacency).and_call_original

    described_class.reconcile(feature_intent:, completion_issue:, client:)

    expect(IssueDependency).to have_received(:account_adjacency).with(project.account).exactly(3).times
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

  it "reopens a completed cycle when a new finding is persisted" do
    completion = FeatureIntentCompletion.create!(
      feature_intent:, completion_issue:, status: "complete", completed_at: Time.current
    )
    prior_cycle = completion.cycle

    result = described_class.record_finding(
      feature_intent:, completion_issue:, client:, affected_issue: implementation_issue,
      fingerprint: "d" * 64, finding: { summary: "A late finding requires work." }
    )

    expect(result).to be_success
    expect(completion.reload).to have_attributes(status: "pending", cycle: prior_cycle + 1, completed_at: nil)
    expect(completion.pending_operations).to be_empty
    expect(remote_bodies.fetch(completion_issue.github_number)).to include("Depends on #701")
  end

  it "reports a dependency cycle instead of treating it as reconciled" do
    IssueDependency.create!(issue: implementation_issue, depends_on_issue: completion_issue)
    implementation_issue.update!(github_state: "closed")

    result = described_class.complete(
      feature_intent:, completion_issue:, client:, acceptance_verified: true,
      isolation: { actual: "isolated" }, release_authorized: true
    )

    expect(result.code).to eq(:dependency_cycle)
    expect(completion_issue.reload.dependencies).not_to include(implementation_issue)
  end

  it "rejects linked issues from another project" do
    foreign_issue = create(:issue, project: create(:project), github_number: 900)

    expect {
      FeatureIntentCompletion.create!(feature_intent:, completion_issue: foreign_issue)
    }.to raise_error(ActiveRecord::RecordInvalid, /must belong to the feature intent's project/)

    completion = FeatureIntentCompletion.create!(feature_intent:, completion_issue:)
    expect {
      completion.forward_work_items.create!(fingerprint: "f" * 64, affected_issue: foreign_issue)
    }.to raise_error(ActiveRecord::RecordInvalid, /must belong to the feature intent's project/)

    expect {
      completion.forward_work_items.create!(fingerprint: "g" * 64, follow_up_issue: foreign_issue)
    }.to raise_error(ActiveRecord::RecordInvalid, /must belong to the feature intent's project/)
  end
end
