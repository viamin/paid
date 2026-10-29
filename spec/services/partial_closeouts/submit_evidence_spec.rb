# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SubmitEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:actor) { create(:user, account: project.account) }
  let(:identity) { "occurrence-1" }
  let(:notification) do
    create(:notification, account: project.account, subject: issue, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error, blocking: true, metadata: { "prerequisites" => [ { "identity" => identity } ] })
  end

  it "records external evidence as pending validation without releasing the prerequisite" do # @spec PARTIAL-CLOSEOUT-033
    result = described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    expect(result.outcome).to eq("pending_validation")
    expect(notification.reload).to be_active
    expect(notification.metadata.fetch("evidence_submissions").last).to include("actor_id" => actor.id,
      "prerequisite_identity" => identity, "outcome" => "pending_validation")
  end

  it "upgrades a legacy prerequisite notification before recording its evidence" do # @spec PARTIAL-CLOSEOUT-033
    notification.update!(metadata: {
      "prerequisite_identity" => identity,
      "references" => [ { "kind" => "artifact", "label" => "Pilot report", "revision" => "v1" } ]
    })

    described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    occurrence = notification.reload.metadata.fetch("prerequisites").sole
    expect(occurrence).to include("identity" => identity, "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue))
    expect(notification.metadata.fetch("evidence_submissions")).to contain_exactly(
      include("prerequisite_identity" => identity, "outcome" => "pending_validation")
    )
    expect(notification).to be_active
  end

  it "rejects evidence for a different prerequisite occurrence" do # @spec PARTIAL-CLOSEOUT-033
    expect {
      described_class.call(notification:, actor:, prerequisite_identity: "other",
        evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")
    }.to raise_error(ArgumentError, "prerequisite occurrence is no longer current")
  end

  it "rejects malformed HTTP(S) URLs" do # @spec PARTIAL-CLOSEOUT-033
    [ "https://", "https:///report" ].each do |evidence_url|
      expect {
        described_class.call(notification:, actor:, prerequisite_identity: identity, evidence_url:, explanation: "Pilot report attached.")
      }.to raise_error(ArgumentError, "evidence must be an HTTP(S) URL")
    end
  end

  it "revalidates after locking when reconciliation resolves the notification" do # @spec PARTIAL-CLOSEOUT-033
    allow(notification).to receive(:with_lock).and_wrap_original do |original, &block|
      notification.update!(resolved_at: Time.current)
      original.call(&block)
    end

    expect {
      described_class.call(notification:, actor:, prerequisite_identity: identity,
        evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")
    }.to raise_error(ArgumentError, "notification is no longer active")
    expect(notification.reload.metadata).not_to have_key("evidence_submissions")
  end

  it "marks evidence stale when the prerequisite source revision changed" do # @spec PARTIAL-CLOSEOUT-033
    source_revision = Issues::CloseoutEvidence.call(issue).digest
    create(:agent_run, :completed, project:, issue:,
      reconciliation: { "assessment" => { "source_revision" => source_revision } })
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity, "source_revision" => source_revision } ] })
    create(:issue, :pull_request, project:, parent_issue: issue, github_state: "closed", pr_review_phase: "merged")

    result = described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    expect(result.outcome).to eq("stale")
    expect(notification.reload).to be_active
  end

  it "keeps evidence pending when the current revision includes technical prerequisite evidence" do # @spec PARTIAL-CLOSEOUT-033
    create(:agent_run, :completed, project:, issue:, reconciliation: {
      TechnicalPrerequisites::Evidence::RECONCILIATION_KEY => { "status" => "completed", "exit_code" => 0 }
    })
    source_revision = PartialCloseouts::Assessment.source_revision_for(issue)
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity, "source_revision" => source_revision } ] })

    result = described_class.call(notification:, actor:, prerequisite_identity: identity,
      evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.")

    expect(result.outcome).to eq("pending_validation")
  end

  it "does not enqueue duplicate validation for an identical submission retry" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }

    expect {
      described_class.call(**attributes)
      described_class.call(**attributes)
    }.to have_enqueued_job(PartialCloseouts::ValidateEvidenceJob)
      .with(notification.id, identity, attributes[:evidence_url], attributes[:explanation]).exactly(1).times

    expect(notification.reload.metadata.fetch("evidence_submissions")).to contain_exactly(
      include("prerequisite_identity" => identity, "evidence_url" => attributes[:evidence_url])
    )
  end

  it "preserves an identical insufficient submission without revalidating it" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)
    PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "insufficient", validator: actor)

    result = nil
    expect { result = described_class.call(**attributes) }
      .not_to have_enqueued_job(PartialCloseouts::ValidateEvidenceJob)

    expect(result.outcome).to eq("insufficient")
    expect(notification.reload.metadata.fetch("evidence_submissions").sole).to include("outcome" => "insufficient")
  end

  it "reconciles validated sufficient evidence and releases a completed blocker" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)

    result = PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(result).to be_sufficient
    expect(notification.reload).not_to be_active
    expect(notification.metadata.fetch("evidence_submissions").sole).to include(
      "outcome" => "sufficient", "validator_id" => actor.id
    )
  end

  it "treats a duplicate validator completion after resolution as a no-op" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)

    PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "sufficient", validator: actor)
    result = PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(result).to be_nil
    expect(notification.reload).not_to be_active
  end

  it "keeps the blocker active when validation is insufficient" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)

    result = PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "insufficient", validator: actor)

    expect(result.outcome).to eq("insufficient")
    expect(notification.reload).to be_active
  end

  it "keeps the blocker active and records stale when validation races a new source revision" do # @spec PARTIAL-CLOSEOUT-033
    source_revision = PartialCloseouts::Assessment.source_revision_for(issue)
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity, "source_revision" => source_revision } ] })
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)
    create(:issue, :pull_request, project: issue.project, parent_issue: issue, github_state: "closed", pr_review_phase: "merged")

    result = PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(result.outcome).to eq("stale")
    expect(notification.reload).to be_active
  end

  it "records stale when reconciliation replaces the submitted occurrence" do # @spec PARTIAL-CLOSEOUT-033
    attributes = { notification:, actor:, prerequisite_identity: identity,
                   evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached." }
    described_class.call(**attributes)
    notification.update!(metadata: notification.metadata.merge(
      "prerequisites" => [ { "identity" => "replacement", "source_revision" => "new-revision" } ]
    ))

    result = PartialCloseouts::ReconcileEvidence.call(**attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(result.outcome).to eq("stale")
    expect(notification.reload).to be_active
  end

  it "releases the guard only after every current occurrence is sufficient" do # @spec PARTIAL-CLOSEOUT-033
    second_identity = "occurrence-2"
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity }, { "identity" => second_identity } ] })
    attributes = { notification:, actor:, evidence_url: "https://evidence.example.test/report", explanation: "Validated report." }
    described_class.call(prerequisite_identity: identity, **attributes)
    described_class.call(prerequisite_identity: second_identity, **attributes)

    PartialCloseouts::ReconcileEvidence.call(prerequisite_identity: identity,
      **attributes.except(:actor), outcome: "sufficient", validator: actor)
    expect(notification.reload).to be_active

    PartialCloseouts::ReconcileEvidence.call(prerequisite_identity: second_identity,
      **attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(notification.reload.resolved_at).to be_present
    expect(notification.metadata.fetch("released_by")).to eq("reconciled_evidence")
  end

  it "does not release while newer evidence for a current occurrence is pending" do # @spec PARTIAL-CLOSEOUT-033
    second_identity = "occurrence-2"
    notification.update!(metadata: { "prerequisites" => [ { "identity" => identity }, { "identity" => second_identity } ] })
    attributes = { notification:, actor:, evidence_url: "https://evidence.example.test/report", explanation: "Validated report." }
    described_class.call(prerequisite_identity: identity, **attributes)
    PartialCloseouts::ReconcileEvidence.call(prerequisite_identity: identity,
      **attributes.except(:actor), outcome: "sufficient", validator: actor)
    described_class.call(prerequisite_identity: identity, **attributes.merge(explanation: "Updated report."))
    described_class.call(prerequisite_identity: second_identity, **attributes)

    PartialCloseouts::ReconcileEvidence.call(prerequisite_identity: second_identity,
      **attributes.except(:actor), outcome: "sufficient", validator: actor)

    expect(notification.reload).to be_active
  end

  it "rejects reconciliation without a matching pending submission" do # @spec PARTIAL-CLOSEOUT-033
    expect {
      PartialCloseouts::ReconcileEvidence.call(notification:, prerequisite_identity: identity,
        evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached.", outcome: "sufficient")
    }.to raise_error(ArgumentError, "pending submitted evidence was not found")
    expect(notification.reload).to be_active
  end
end
