# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::Authorization do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }
  let(:criterion) { "Representative staging environment is approved" }

  def occurrence(identity: "auth-1", source_revision: PartialCloseouts::Assessment.source_revision_for(issue))
    { "identity" => identity, "criterion" => criterion, "kind" => "human",
      "workflow" => TechnicalPrerequisites::AUTHORIZATION_WORKFLOW, "source_revision" => source_revision }
  end

  def notification_with(occurrences, evidence_submissions: [])
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Approve the representative environment",
      description: "Approve the representative staging environment for this measurement.",
      metadata: { "prerequisites" => occurrences, "evidence_submissions" => evidence_submissions })
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "grants a criterion with no partial-closeout prerequisite notification" do
    expect(described_class.granted?(issue:, criterion:)).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "grants a criterion whose notification has no matching authorization occurrence" do
    notification_with([ occurrence.merge("criterion" => "Unrelated criterion") ])

    expect(described_class.granted?(issue:, criterion:)).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "grants a criterion whose matching occurrence is not the authorization workflow" do
    notification_with([ occurrence.merge("workflow" => nil) ])

    expect(described_class.granted?(issue:, criterion:)).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "withholds a criterion whose authorization occurrence has no sufficient submission" do
    notification_with([ occurrence ])

    expect(described_class.granted?(issue:, criterion:)).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "withholds a criterion whose authorization occurrence was marked insufficient" do
    notification_with([ occurrence ], evidence_submissions: [
      { "prerequisite_identity" => "auth-1", "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "outcome" => "insufficient" }
    ])

    expect(described_class.granted?(issue:, criterion:)).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "grants a criterion whose authorization occurrence has a current sufficient submission" do
    revision = PartialCloseouts::Assessment.source_revision_for(issue)
    notification_with([ occurrence(source_revision: revision) ], evidence_submissions: [
      { "prerequisite_identity" => "auth-1", "source_revision" => revision, "outcome" => "sufficient" }
    ])

    expect(described_class.granted?(issue:, criterion:)).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-048
  it "withholds a criterion whose sufficient submission is stale against the current revision" do
    notification_with([ occurrence(source_revision: "stale-revision") ], evidence_submissions: [
      { "prerequisite_identity" => "auth-1", "source_revision" => "stale-revision", "outcome" => "sufficient" }
    ])

    expect(described_class.granted?(issue:, criterion:)).to be(false)
  end
end
