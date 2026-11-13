# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::Authorization do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:identifier) { "representative-environment-v1" }
  let(:revision) { PartialCloseouts::Assessment.source_revision_for(issue) }
  let(:occurrence) do
    { "identity" => "authorization-occurrence", "technical_authorization_id" => identifier,
      "source_revision" => revision, "source_issue_number" => issue.github_number }
  end

  # @spec PARTIAL-CLOSEOUT-050
  it "requires independently validated current human evidence" do
    create(:notification, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, metadata: {
        "prerequisites" => [ occurrence ], "evidence_submissions" => [ {
          "prerequisite_identity" => occurrence["identity"], "source_revision" => revision,
          "outcome" => "sufficient"
        } ] })

    expect(described_class.granted?(issue:, identifier:)).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-050
  it "does not infer authorization from a technical validation record" do
    create(:agent_run, :completed, project:, issue:, reconciliation: {
      TechnicalPrerequisites::Evidence::RECONCILIATION_KEY => { "status" => "completed", "criterion" => "Measure response time" }
    })

    expect(described_class.granted?(issue:, identifier:)).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-050
  it "rejects sufficient evidence once its source revision is stale" do
    create(:notification, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, metadata: {
        "prerequisites" => [ occurrence ], "evidence_submissions" => [ {
          "prerequisite_identity" => occurrence["identity"], "source_revision" => revision,
          "outcome" => "sufficient"
        } ] })
    create(:issue, :pull_request, project:, parent_issue: issue, github_state: "closed", pr_review_phase: "merged")

    expect(described_class.granted?(issue:, identifier:)).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-050
  it "does not read an authorization from another tenant" do
    other_project = create(:project)
    other_issue = create(:issue, project: other_project, github_number: issue.github_number)
    create(:notification, account: other_project.account, subject: other_issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, metadata: {
        "prerequisites" => [ occurrence.merge("source_issue_number" => issue.github_number) ],
        "evidence_submissions" => [ { "prerequisite_identity" => occurrence["identity"],
          "source_revision" => revision, "outcome" => "sufficient" } ] })

    expect(described_class.granted?(issue:, identifier:)).to be(false)
  end
end
