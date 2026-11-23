# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-012
RSpec.describe PullRequests::TechnicalMergeBlockers do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, :pull_request, project:) }
  let(:owner) { create(:issue, project:) }
  let(:head) { "a" * 40 }

  before do
    owner
    issue
  end

  def record(reason: "SDK reservation can time out")
    described_class.record!(issue:, actor:, key: "safe_worker_adoption", head_sha: head,
      reason:, owner_issue_id: owner.id, release_condition: "Pass the real finite-attempt SDK controls")
  end

  it "records technical work without a label or human approval request" do
    expect { record }.to change { account.account_activity_events.count }.by(1)
    expect(described_class.blocked?(issue.reload)).to be(true)
    expect(issue.labels).to be_empty
    expect(issue.hold_for_review).to be(false)
    expect(described_class.entries(issue).sole).to include("owner_issue_id" => owner.id,
      "head_sha" => head, "release_condition" => "Pass the real finite-attempt SDK controls")
  end

  it "keeps independent blockers when another entry is updated" do
    record
    described_class.record!(issue:, actor:, key: "ci", head_sha: head,
      reason: "Tests fail", owner_issue_id: owner.id, release_condition: "Pass current tests")
    record(reason: "New SDK failure")
    expect(described_class.entries(issue.reload).map { |b| b.fetch("key") }).to contain_exactly("ci", "safe_worker_adoption")
  end

  it "refuses to release a refreshed stop using an old entry version" do
    old = record
    record(reason: "A distinct current failure")
    expect {
      described_class.resolve!(issue:, actor:, key: old.fetch("key"), version: old.fetch("version"),
        head_sha: head, evidence: "Old result")
    }.to raise_error(ArgumentError, /changed/)
    expect(described_class.blocked?(issue.reload)).to be(true)
  end

  it "resolves only the selected entry with applicable evidence and retains a human hold" do
    entry = record
    issue.update!(labels: [ "paid-hold-review" ])
    provider = instance_double(Automation::Providers::Github::RepositoryProvider)
    allow(Automation::Providers::Resolver).to receive(:repository_for).with(project).and_return(provider)
    allow(provider).to receive(:fetch_pull_request).with(repo: project.full_name, number: issue.github_number)
      .and_return(Struct.new(:head_sha).new(head))
    described_class.resolve!(issue:, actor:, key: entry.fetch("key"), version: entry.fetch("version"),
      head_sha: head, evidence: "Current SDK controls passed; receipt 123")
    expect(described_class.blocked?(issue.reload)).to be(false)
    expect(issue.labels).to eq([ "paid-hold-review" ])
    expect(account.account_activity_events.last.metadata).to include("evidence" => "Current SDK controls passed; receipt 123")
  end

  it "rejects an owner outside this project" do
    foreign = create(:issue)
    expect {
      described_class.record!(issue:, actor:, key: "ci", head_sha: head, reason: "Tests fail",
        owner_issue_id: foreign.id, release_condition: "Pass tests")
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "retains the stop when resolution evidence names a stale provider head" do
    entry = record
    provider = instance_double(Automation::Providers::Github::RepositoryProvider)
    allow(Automation::Providers::Resolver).to receive(:repository_for).with(project).and_return(provider)
    allow(provider).to receive(:fetch_pull_request).and_return(Struct.new(:head_sha).new("b" * 40))
    expect {
      described_class.resolve!(issue:, actor:, key: entry.fetch("key"), version: entry.fetch("version"),
        head_sha: head, evidence: "Old head passed")
    }.to raise_error(ArgumentError, /head changed/)
    expect(described_class.blocked?(issue.reload)).to be(true)
  end

  it "refuses backend writes from a viewer" do
    viewer = create(:user, :viewer, account:)
    expect {
      described_class.record!(issue:, actor: viewer, key: "ci", head_sha: head, reason: "Test",
        owner_issue_id: owner.id, release_condition: "Pass")
    }.to raise_error(Pundit::NotAuthorizedError)
  end

  it "fails closed for malformed stored state" do
    issue.update_column(:technical_merge_blockers, { "unexpected" => "payload" })
    expect(described_class.blocked?(issue.reload)).to be(true)
    expect(described_class.entries(issue).sole.fetch("reason")).to include("unavailable")
  end

  it "rejects oversized reasons rather than storing unbounded input" do
    expect { record(reason: "x" * 501) }.to raise_error(ArgumentError, /reason/)
    expect(issue.reload.technical_merge_blockers).to eq([])
  end

  it "rolls back the stop if its audit record cannot be persisted" do
    allow(Audit::RecordEvent).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect { record }.to raise_error(ActiveRecord::RecordInvalid)
    expect(issue.reload.technical_merge_blockers).to be_empty
  end

  it "retains a stop refreshed while resolution is fetching the current head" do
    entry = record
    provider = instance_double(Automation::Providers::Github::RepositoryProvider)
    allow(Automation::Providers::Resolver).to receive(:repository_for).with(project).and_return(provider)
    allow(provider).to receive(:fetch_pull_request) do
      record(reason: "A newly reproduced failure")
      Struct.new(:head_sha).new(head)
    end
    expect {
      described_class.resolve!(issue:, actor:, key: entry.fetch("key"), version: entry.fetch("version"),
        head_sha: head, evidence: "Earlier controls passed")
    }.to raise_error(ArgumentError, /changed/)
    expect(described_class.entries(issue.reload).sole.fetch("reason")).to eq("A newly reproduced failure")
  end
end
