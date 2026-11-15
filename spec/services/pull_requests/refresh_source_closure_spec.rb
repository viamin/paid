# frozen_string_literal: true

require "rails_helper"

RSpec.describe PullRequests::RefreshSourceClosure do
  let(:project) { create(:project) }
  let(:source_issue) { create(:issue, project:, github_number: 7) }
  let(:pull_request) do
    create(:issue, :pull_request, project:, github_number: 42, github_state: "open", parent_issue: source_issue)
  end
  let(:client) { instance_double(GithubClient, update_pull_request: nil) }
  let(:data) do
    Automation::Providers::Data::PullRequest.new(
      number: 42, title: "Test", body: "Summary\n\nTracks #7", state: :open, draft: false,
      merged: false, mergeable: true, head_sha: "head-1", head_ref: "feature", base_ref: "main",
      author_login: "paid", labels: [], created_at: Time.current, updated_at: Time.current,
      merged_at: nil, url: pull_request.github_url, raw_state: "open"
    )
  end

  def record_assessment(head: "head-1", evidence: [ { "label" => "spec/services/example_spec.rb:42" } ])
    run = create(:agent_run, :completed, project:, issue: source_issue,
      goal: "create_pr", pull_request_number: pull_request.github_number, pull_request_url: pull_request.github_url,
      result_commit_sha: head)
    run.update!(reconciliation: { "assessment" => {
      "gaps" => [], "criteria" => [ { "criterion" => "works", "state" => "satisfied", "evidence" => evidence } ],
      "source_revision" => Issues::CloseoutEvidence.call(source_issue).digest,
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(source_issue),
      "pr_head_sha" => head,
      "verification_revision" => PartialCloseouts::Assessment.verification_revision_for(run)
    } })
    run
  end

  it "promotes a current-head source PR with cited evidence" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment

    result = described_class.call(pull_request:, pull_request_data: data, client:)

    expect(result).to have_attributes(evaluated: true, updated: true, disposition: "close")
    expect(client).to have_received(:update_pull_request).with(project.pr_target_repository, 42, body: "Summary\n\nCloses #7")
  end

  it "uses the latest follow-up verification for the source PR" do # @spec PARTIAL-CLOSEOUT-050
    assessment_run = record_assessment
    followup_run = create(:agent_run, :completed, project:, issue: source_issue, goal: "create_pr",
      source_pull_request_number: pull_request.github_number, result_commit_sha: "head-1",
      verification_result: { "status" => "passed", "summary" => "follow-up verification" })
    assessment_run.update!(reconciliation: assessment_run.reconciliation.deep_merge(
      "assessment" => { "verification_revision" => PartialCloseouts::Assessment.verification_revision_for(followup_run) }
    ))

    result = described_class.call(pull_request:, pull_request_data: data, client:)

    expect(result).to have_attributes(evaluated: true, updated: true, disposition: "close")
  end

  it "demotes a stale closing reference when the head changes" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment(head: "old-head")
    stale_data = data.with(body: "Summary\n\nCloses #7", head_sha: "new-head")

    result = described_class.call(pull_request:, pull_request_data: stale_data, client:)

    expect(result).to have_attributes(updated: true, disposition: "track")
    expect(client).to have_received(:update_pull_request).with(project.pr_target_repository, 42, body: "Summary\n\nTracks #7")
  end

  it "demotes a closing reference when verification is later skipped" do # @spec PARTIAL-CLOSEOUT-050
    run = record_assessment
    run.update!(verification_result: { "status" => "skipped", "reason" => "tests unavailable" })

    result = described_class.call(
      pull_request:, pull_request_data: data.with(body: "Summary\n\nCloses #7"), client:
    )

    expect(result).to have_attributes(updated: true, disposition: "track")
    expect(client).to have_received(:update_pull_request).with(project.pr_target_repository, 42, body: "Summary\n\nTracks #7")
  end

  it "demotes a closing reference when the latest acceptance audit failed" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment
    create(:agent_run, :failed, project:, issue: source_issue, goal: "analyze_issue",
      reconciliation: { "acceptance_audit_failure" => { "category" => "transport_error" } })

    result = described_class.call(
      pull_request:, pull_request_data: data.with(body: "Summary\n\nCloses #7"), client:
    )

    expect(result).to have_attributes(updated: true, disposition: "track")
    expect(client).to have_received(:update_pull_request).with(project.pr_target_repository, 42, body: "Summary\n\nTracks #7")
  end

  it "does not promote criteria without cited evidence" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment(evidence: [])

    result = described_class.call(pull_request:, pull_request_data: data, client:)

    expect(result).to have_attributes(updated: false, disposition: "track")
  end

  it "leaves the merge boundary retryable when GitHub rejects the body update" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment
    allow(client).to receive(:update_pull_request).and_raise(GithubClient::ApiError, "unavailable")

    expect { described_class.call(pull_request:, pull_request_data: data, client:) }
      .to raise_error(GithubClient::ApiError, "unavailable")
  end

  it "does not edit a merged PR" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment

    result = described_class.call(pull_request:, pull_request_data: data.with(merged: true), client:)

    expect(result.evaluated).to be(false)
    expect(client).not_to have_received(:update_pull_request)
  end

  it "does not edit a fetched closed, unmerged PR while the local row is stale" do # @spec PARTIAL-CLOSEOUT-050
    record_assessment

    result = described_class.call(
      pull_request:, pull_request_data: data.with(state: :closed, raw_state: "closed"), client:
    )

    expect(result.evaluated).to be(false)
    expect(client).not_to have_received(:update_pull_request)
  end
end
