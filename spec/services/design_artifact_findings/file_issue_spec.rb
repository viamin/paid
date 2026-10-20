# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe DesignArtifactFindings::FileIssue do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "widget") }
  let(:finding) { create(:design_artifact_finding, account:, project:) }
  let(:client) { instance_double(GithubClient) }
  let(:remote) do
    OpenStruct.new(
      id: 2_000_001, number: 42,
      title: "Repair traceability for docs/rdrs/RDR-100.md",
      body: "Filed via Inbox", state: "open", labels: [], user: nil,
      created_at: Time.current, updated_at: Time.current,
      html_url: "https://github.com/acme/widget/issues/42", pull_request: nil
    )
  end

  before do
    allow(client).to receive_messages(
      create_issue: remote,
      search_issues: Data.define(:items).new([])
    )
    allow(project).to receive(:client).and_return(client)
  end

  # @spec OPERATOR-INBOX-018
  it "files a new GitHub issue and assigns the finding to it in one call" do
    issue = described_class.call(
      finding:, user:, title: "Repair traceability for docs/rdrs/RDR-100.md",
      body: "Cite the artifact and the intended repair.", revision: finding.revision
    )

    expect(issue).to be_a(Issue)
    expect(issue.github_number).to eq(42)
    expect(finding.reload).to have_attributes(
      status: "assigned", resolution_state: "assigned",
      resolution_reason: "Filed as #42 to own the document repair.",
      resolution_actor: user, resolution_issue: issue
    )
    expect(client).to have_received(:create_issue).with(
      project.full_name, title: "Repair traceability for docs/rdrs/RDR-100.md",
      body: include("## Traceability finding context", "`#{finding.artifact_path}`", "`#{finding.revision}`", "Reconciliation evidence:"),
      labels: anything
    )
  end

  # @spec OPERATOR-INBOX-018
  it "is idempotent across retries that carry the same revision" do
    allow(client).to receive(:create_issue).and_return(remote)

    first = described_class.call(
      finding:, user:, title: "Repair traceability", body: "Cite repair.",
      revision: finding.revision
    )
    second = described_class.call(
      finding:, user:, title: "Repair traceability (retry)", body: "Cite repair again.",
      revision: finding.revision
    )

    expect(first.id).to eq(second.id)
    expect(client).to have_received(:create_issue).once
    expect(finding.reload.resolution_issue_id).to eq(first.id)
  end

  # @spec OPERATOR-INBOX-018
  it "recovers a remotely filed issue by marker before retrying creation" do
    remote.body = "Cite repair.\n\n<!-- paid-traceability-finding:#{finding.id}:#{finding.revision} -->"
    allow(client).to receive(:search_issues)
      .with(%(repo:#{project.full_name} is:issue state:open in:body "<!-- paid-traceability-finding:#{finding.id}:#{finding.revision} -->"), per_page: 100)
      .and_return(Data.define(:items).new([ remote ]))

    issue = described_class.call(
      finding:, user:, title: "Repair traceability", body: "Cite repair.", revision: finding.revision
    )

    expect(issue.github_number).to eq(remote.number)
    expect(client).not_to have_received(:create_issue)
    expect(finding.reload).to have_attributes(status: "assigned", resolution_issue: issue)
  end

  # @spec OPERATOR-INBOX-018
  it "does not reuse an assigned issue that belongs to a different project" do
    other_project = create(:project, account:, created_by: user)
    foreign_issue = create(:issue, project: other_project, github_state: "open")
    finding.update_columns(resolution_issue_id: foreign_issue.id)

    expect(client).to receive(:create_issue).once.and_return(remote)

    described_class.call(
      finding:, user:, title: "Repair", body: "Body", revision: finding.revision
    )
  end

  # @spec OPERATOR-INBOX-018
  it "rejects a stale revision before contacting GitHub" do
    expect do
      described_class.call(
        finding:, user:, title: "Repair", body: "Body", revision: "different"
      )
    end.to raise_error(ArgumentError, "finding changed; reload before filing")

    expect(client).not_to have_received(:create_issue)
    expect(finding.reload.status).to eq("open")
  end

  # @spec OPERATOR-INBOX-018
  it "requires a title and a body" do
    expect do
      described_class.call(finding:, user:, title: "", body: "Body", revision: finding.revision)
    end.to raise_error(ArgumentError, "a title is required")

    expect do
      described_class.call(finding:, user:, title: "Title", body: "  ", revision: finding.revision)
    end.to raise_error(ArgumentError, "a body is required")

    expect(client).not_to have_received(:create_issue)
  end
end
