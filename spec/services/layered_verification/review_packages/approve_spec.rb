# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::ReviewPackages::Approve do
  # @spec LAYERED-VERIFY-023
  it "records the reviewer's decision at the bound revision with actor, time and provenance" do
    audit, package, obligation, user = captured_package
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)

    approval = nil
    expect {
      approval = described_class.call(package:, user:, provenance: { "surface" => "ui", "note" => "Walkthrough done" })
    }.to change { audit.review_packages.count }.by(1)

    expect(approval).to have_attributes(package:, approved_by: user)
    expect(approval.approved_at).to be_within(1.minute).of(Time.current)
    expect(approval.provenance).to include(
      "surface" => "ui", "note" => "Walkthrough done",
      "package_digest" => package.package_digest,
      "bound_revisions" => include(obligation.external_identity => obligation.external_revision)
    )
    successor = audit.review_packages.order(:revision_number).last
    expect(package.reload.bound_inputs.fetch("approval_ids")).to be_empty
    expect(successor.revision_number).to eq(package.revision_number + 1)
    expect(successor.bound_inputs.fetch("approval_ids")).to eq([ approval.id ])
    expect(successor.package_digest).to eq(LayeredVerificationReviewPackage.digest_for(successor.bound_inputs))
  end

  # @spec LAYERED-VERIFY-023
  it "requires refreshed review when a newer package revision exists" do
    audit, _package, obligation, user = captured_package
    stale = audit.review_packages.sole
    obligation.check_results.create!(
      producer: "semantic_audit", execution_state: "completed", obligation_coverage: "unresolved",
      input_revision: { "target_revision" => "abc123" }, agent_run: audit, limitations: "A second bounded read."
    )
    LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)

    expect { described_class.call(package: stale, user:, provenance: { "surface" => "ui" }) }
      .to raise_error(LayeredVerification::ReviewPackages::Approve::StalePackageError, /newer review package revision/)
    expect(stale.approvals).to be_empty
  end

  # @spec LAYERED-VERIFY-023
  it "requires refreshed review when a bound obligation source moved past the bound revision" do
    audit, package, obligation, user = captured_package
    obligation.update!(external_revision: "moved-on")
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)

    expect { described_class.call(package:, user:, provenance: { "surface" => "ui" }) }
      .to raise_error(LayeredVerification::ReviewPackages::Approve::StalePackageError, /obligation source changed/)
    expect(package.approvals).to be_empty
  end

  # @spec LAYERED-VERIFY-023
  it "does not by itself start a repair, approve a clarification, or authorize release" do
    audit, package, obligation, user = captured_package
    finding = create(:layered_verification_finding, project: audit.project, obligation:, agent_run: audit)
    decision_before = finding.decision.deep_dup
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)

    run_count = AgentRun.count
    expect { described_class.call(package:, user:, provenance: { "surface" => "ui" }) }
      .not_to have_enqueued_job(ProcessRunQueueJob)
    expect(AgentRun.count).to eq(run_count)
    expect(obligation.reload).to have_attributes(approval_state: "proposed")
    expect(finding.reload.decision).to eq(decision_before)
    expect(audit.reload.status).to eq("completed")
  end

  # @spec LAYERED-VERIFY-023
  it "refuses approval when the add-on is disabled or the actor is unauthorized" do
    audit, package, = captured_package
    user = audit.project.created_by
    outsider = create(:user, :owner, account: create(:account))
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(false)

    expect { described_class.call(package:, user:, provenance: { "surface" => "ui" }) }
      .to raise_error(LayeredVerification::AuditAccess::FeatureDisabledError)

    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)

    expect { described_class.call(package:, user: outsider, provenance: { "surface" => "ui" }) }
      .to raise_error(LayeredVerification::AuditAccess::UnauthorizedError)
    expect(package.approvals).to be_empty
  end

  private

  def captured_package
    account = create(:account)
    user = create(:user, :owner, account:)
    project = create(:project, account:, created_by: user)
    audit = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    obligation = create(:layered_verification_obligation, project:)
    audit.update!(external_metadata: {
      "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
                                  "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } } }
    })
    create(:layered_verification_check_result, obligation:, agent_run: audit,
      input_revision: { "target_revision" => "abc123" })
    package = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    [ audit, package, obligation, user ]
  end
end
