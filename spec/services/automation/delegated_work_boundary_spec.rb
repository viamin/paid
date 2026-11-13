# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::DelegatedWorkBoundary do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, github_creator_login: "trusted-user") }
  let(:authorization) do
    create(:bounded_delegated_action, account:, project:, issue:, evidence: evidence)
  end
  let(:evidence) do
    {
      "intent_digest" => "sha256:#{Digest::SHA256.hexdigest("intent")}",
      "acceptance_refs" => [ "AC-1" ],
      "intent_revision" => "intent-7",
      "acceptance_revision" => "acceptance-3",
      "evidence_revision" => "evidence-9",
      "posture_signature" => "posture:4",
      "phase" => "coding",
      "stop_before_phase" => "merge"
    }
  end
  let(:snapshot) do
    {
      intent_revision: "intent-7",
      acceptance_revision: "acceptance-3",
      evidence_revision: "evidence-9",
      posture_signature: "posture:4",
      phase: "coding",
      phase_policy: true,
      account_id: account.id,
      project_id: project.id,
      issue_id: issue.id,
      security: true,
      trust: true,
      budget: true,
      repository_controls: true,
      assessment_available: true
    }
  end

  def recheck(overrides = {})
    described_class.call(
      authorization:,
      boundary: :retry,
      snapshot: snapshot.merge(overrides)
    )
  end

  it "permits a delegated action when every boundary input is current" do # @spec PROJECT-DELEGATION-004 BOUNDED-PHASE-AUTHORIZATION-004
    expect(recheck).to be_permitted
    expect(Notification.count).to eq(0)
  end

  it "applies the same recheck contract to every delegated-work boundary" do # @spec PROJECT-DELEGATION-004
    Automation::DelegatedWorkBoundary::BOUNDARIES.each do |boundary|
      expect(described_class.call(authorization:, boundary:, snapshot:)).to be_permitted
    end
  end

  it "routes stale revisions and posture changes to one focused decision" do # @spec PROJECT-DELEGATION-004 PROJECT-DELEGATION-006
    first = recheck(intent_revision: "intent-8")
    second = recheck(posture_signature: "posture:5")

    expect(first).to be_blocked
    expect(first.reasons).to include(:intent_revision)
    expect(second).to be_blocked
    expect(second.reasons).to include(:posture_signature)
    expect(Notification.where(source: described_class::NOTIFICATION_SOURCE).count).to eq(1)
    # The reused decision represents the latest failure, so the operator is
    # never pointed at an authorization, boundary, or reason that no longer
    # blocks the work.
    expect(Notification.last.metadata).to include(
      "authorization_id" => authorization.id,
      "boundary" => "retry",
      "reasons" => [ "posture_signature" ]
    )
  end

  it "checks phase and bounded stop policy before starting another action" do # @spec PROJECT-DELEGATION-004 BOUNDED-PHASE-AUTHORIZATION-003
    result = recheck(phase: "merge")

    expect(result).to be_blocked
    expect(result.reasons).to include(:phase, :bounded_stop)
  end

  it "fails closed when the current phase policy cannot be resolved" do # @spec BOUNDED-PHASE-AUTHORIZATION-004
    result = recheck(phase_policy: nil)

    expect(result).to be_blocked
    expect(result.reasons).to include(:phase_policy)
    expect(Notification.last.metadata["reasons"]).to include("phase_policy")
  end

  it "fails closed for tenant, trust, budget, repository, or assessment failures" do # @spec PROJECT-DELEGATION-004 PROJECT-DELEGATION-007
    FeatureFlags.enable!(:project_delegation, project:)
    %i[account_id project_id trust budget repository_controls assessment_available].each do |key|
      result = recheck(key => key == :account_id ? account.id + 1 : false)

      expect(result).to be_blocked, "expected #{key} to block"
      expected_reason = if key.in?(%i[account_id project_id])
        :tenant
      elsif key == :assessment_available
        :assessment_availability
      else
        key
      end
      expect(result.reasons).to include(expected_reason)
    end
    expect(InboxHistoryEvent.where(source: "project_delegation_pilot").pluck(:result))
      .to include("tenant_breach", "trust_breach", "evidence_missing")
  end

  it "holds delegated work when the operator has placed the work item on hold" do # @spec PROJECT-DELEGATION-006
    issue.update!(hold_for_review: true)

    result = recheck(explicit_hold: true)

    expect(result).to be_blocked
    expect(result.reasons).to include(:explicit_hold)
  end

  it "reports expiry separately from other lifecycle failures" do # @spec PROJECT-DELEGATION-006
    authorization.update!(expires_at: 1.second.ago)

    result = recheck

    expect(result).to be_blocked
    expect(result.reasons).to include(:expiry)
  end

  it "fails closed and records a security pause when security assessment is unavailable" do # @spec PROJECT-DELEGATION-007
    FeatureFlags.enable!(:project_delegation, project:)

    result = described_class.call(authorization:, boundary: :retry, snapshot: snapshot.except(:security))

    expect(result).to be_blocked
    expect(result.reasons).to include(:security)
    expect(InboxHistoryEvent.where(source: "project_delegation_pilot").pluck(:result))
      .to include("security_breach")
  end

  it "rejects unsupported boundaries" do
    expect { described_class.call(authorization:, boundary: :execute, snapshot:) }
      .to raise_error(ArgumentError, /unsupported delegated-work boundary/)
  end
end
