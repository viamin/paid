# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationReviewPackage do
  # @spec LAYERED-VERIFY-023
  it "computes one reproducible identity over the bound inputs" do
    bound = {
      "agent_run_id" => 7, "target_revision" => "abc",
      "obligations" => [ { "id" => 1, "external_identity" => "PAYMENTS-1", "external_revision" => "r1",
                           "scope_description" => "Process a checkout payment." } ],
      "plan_revision" => "plan-digest", "check_result_ids" => [ 11 ], "approval_ids" => [],
      "inbox_decisions" => []
    }
    reordered = {
      "inbox_decisions" => [], "approval_ids" => [], "check_result_ids" => [ 11 ],
      "plan_revision" => "plan-digest",
      "obligations" => [ { "scope_description" => "Process a checkout payment.", "external_revision" => "r1",
                           "external_identity" => "PAYMENTS-1", "id" => 1 } ],
      "target_revision" => "abc", "agent_run_id" => 7
    }

    expect(described_class.digest_for(bound)).to eq(described_class.digest_for(reordered))
    expect(described_class.digest_for(bound)).to match(/\A[0-9a-f]{64}\z/)
    expect(described_class.digest_for(bound.merge("target_revision" => "def")))
      .not_to eq(described_class.digest_for(bound))
  end

  # @spec LAYERED-VERIFY-023
  it "captures a package binding every declared input at creation" do
    audit = completed_audit
    obligation = audit.project.layered_verification_obligations.sole

    package = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

    expect(package.bound_inputs).to include(
      "agent_run_id" => audit.id,
      "target_revision" => "abc123",
      "obligations" => [ include("id" => obligation.id, "external_identity" => obligation.external_identity,
                                 "external_revision" => obligation.external_revision,
                                 "scope_description" => obligation.scope_description) ],
      "plan_revision" => be_a(String),
      "check_result_ids" => [ obligation.check_results.sole.id ]
    )
    expect(package.package_digest).to eq(described_class.digest_for(package.bound_inputs))
    expect(package).to have_attributes(project: audit.project, revision_number: 1)
  end

  # @spec LAYERED-VERIFY-023
  it "replays an unchanged capture idempotently and a changed input as a new preserved revision" do
    audit = completed_audit
    obligation = audit.project.layered_verification_obligations.sole
    first = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

    replay = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    expect(replay.id).to eq(first.id)
    expect(audit.review_packages.count).to eq(1)

    obligation.check_results.create!(
      producer: "semantic_audit", execution_state: "completed", obligation_coverage: "unresolved",
      input_revision: { "target_revision" => "abc123", "external_revision" => obligation.external_revision },
      agent_run: audit, limitations: "A second bounded read."
    )
    second = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

    expect(second.revision_number).to eq(2)
    expect(second.package_digest).not_to eq(first.package_digest)
    expect(audit.review_packages.find(first.id)).to have_attributes(
      package_digest: first.package_digest, bound_inputs: first.bound_inputs, revision_number: 1
    )
  end

  # @spec LAYERED-VERIFY-023
  it "keeps capture concurrency-safe within one lineage" do
    audit = completed_audit
    threads = Array.new(3) { Thread.new { LayeredVerification::ReviewPackages::Capture.call(agent_run: audit) } }
    packages = threads.map(&:value)

    expect(audit.review_packages.count).to eq(1)
    expect(packages.map(&:id)).to all(eq(packages.first.id))
  end

  # @spec LAYERED-VERIFY-023
  it "rejects any mutation of a persisted package" do
    package = LayeredVerification::ReviewPackages::Capture.call(agent_run: completed_audit)

    expect { package.update!(bound_inputs: { "tampered" => true }) }
      .to raise_error(LayeredVerificationReviewPackage::ImmutablePackageError)
    expect { package.destroy }.to raise_error(LayeredVerificationReviewPackage::ImmutablePackageError)
  end

  # @spec LAYERED-VERIFY-023
  it "rejects any mutation of a persisted approval" do
    approval = create(:layered_verification_review_approval)

    expect { approval.update!(provenance: { "tampered" => true }) }
      .to raise_error(LayeredVerificationReviewPackage::ImmutablePackageError)
    expect(approval.reload.provenance).to eq("surface" => "spec")
  end

  # @spec LAYERED-VERIFY-023
  it "rejects packages whose audit run belongs to another project" do
    other_project = create(:project, account: create(:account))
    audit = create(:agent_run, project: other_project, goal: "layered_verification_audit")
    project = create(:project)

    package = build(:layered_verification_review_package, project:, agent_run: audit)

    expect(package).not_to be_valid
    expect(package.errors[:agent_run]).to include("must belong to the same project")
  end

  # @spec LAYERED-VERIFY-023
  it "binds approvals and Inbox decisions recorded while the package is open" do
    audit = completed_audit
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project: audit.project)
      .and_return(true)
    package = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    obligation = audit.project.layered_verification_obligations.sole
    LayeredVerification::ReviewPackages::Approve.call(
      package:, user: audit.project.created_by, provenance: { "surface" => "ui" }
    )
    finding = create(:layered_verification_finding, project: audit.project, obligation:, agent_run: audit)
    finding.update!(decision: finding.decision.merge(
      "selected_action" => "defer", "decided_at" => Time.current.iso8601, "reason" => "waiting on the owner"
    ))

    successor = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

    expect(successor.revision_number).to eq(2)
    expect(successor.bound_inputs["approval_ids"]).to eq(package.approvals.map(&:id))
    expect(successor.bound_inputs["inbox_decisions"]).to contain_exactly(
      include("finding_id" => finding.id, "selected_action" => "defer")
    )
  end

  # @spec LAYERED-VERIFY-023
  it "answers whether it is the current revision of its lineage" do
    audit = completed_audit
    first = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)
    obligation = audit.project.layered_verification_obligations.sole
    expect(first).to be_current

    obligation.check_results.create!(
      producer: "semantic_audit", execution_state: "completed", obligation_coverage: "unresolved",
      input_revision: { "target_revision" => "abc123" }, agent_run: audit, limitations: "A second bounded read."
    )
    second = LayeredVerification::ReviewPackages::Capture.call(agent_run: audit)

    expect(first.reload).not_to be_current
    expect(second).to be_current
    expect(first.reload.bound_inputs).to be_present
  end

  private

  def completed_audit
    account = create(:account)
    user = create(:user, :owner, account:)
    project = create(:project, account:, created_by: user)
    audit = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    obligation = create(:layered_verification_obligation, project:)
    audit.update!(external_metadata: {
      "layered_verification" => {
        "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ],
                                            "fit" => "Bounded review", "exclusions" => [] } }
      }
    })
    create(:layered_verification_check_result, obligation:, agent_run: audit,
      input_revision: { "target_revision" => "abc123" })
    audit
  end
end
