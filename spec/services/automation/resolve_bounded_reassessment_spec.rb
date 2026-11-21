# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-005
RSpec.describe Automation::ResolveBoundedReassessment do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:authorization) do
    create(:bounded_delegated_action, account: account, project: project, issue: issue, created_by: user,
      action: "repair",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue, action: "repair", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  before do
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    project.update!(automation_phase_settings: {
      "phases" => { "coding" => true, "merge" => true }
    })
    create(:project_delegation_posture, project: project, level: "bounded_delivery", revision: 1, selected_by: user)
    assessment_run = create(:agent_run, :completed, project: project, issue: issue)
    assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
      assessment_run, { "criteria" => [], "gaps" => [] }
    ) })
  end

  # The reviewer's example: a guard rollback invalidates the pinned policy
  # signature and phase policy while the authorization is paused for it.
  def pause_for_policy_rollback!
    authorization # evidence must pin the enabled policy before the rollback
    FeatureFlags.disable!(:project_delegation, project: project)
    authorization.require_reassessment!(reasons: [ :posture_signature, :phase_policy ])
  end

  it "keeps the pause while the policy mismatch that triggered it still holds" do
    pause_for_policy_rollback!

    expect { described_class.call(authorization: authorization, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /posture_signature/)
    expect(authorization.reload).to be_reassessment_required
    expect(AccountActivityEvent.where(action: "bounded_action.reassessment_resumed")).to be_empty
  end

  it "resumes the unchanged authorization after the triggering policy is restored" do
    pause_for_policy_rollback!
    FeatureFlags.enable!(:project_delegation, project: project)
    original_evidence = authorization.evidence.deep_dup

    expect(described_class.call(authorization: authorization, user: user, resolution: :resume)).to eq(:resumed)
    expect(authorization.reload).to be_active
    expect(authorization.evidence).to eq(original_evidence)
    expect(AccountActivityEvent.last.action).to eq("bounded_action.reassessment_resumed")
  end

  it "keeps the pause when a new trigger appeared after the pause" do
    pause_for_policy_rollback!
    FeatureFlags.enable!(:project_delegation, project: project)
    issue.update!(title: "A materially different request")

    expect { described_class.call(authorization: authorization, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /intent_revision/)
    expect(authorization.reload).to be_reassessment_required
  end

  it "keeps the pause for an expired authorization" do
    pause_for_policy_rollback!
    FeatureFlags.enable!(:project_delegation, project: project)
    authorization.update!(expires_at: 1.hour.ago)

    expect { described_class.call(authorization: authorization, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /expiry/)
    expect(authorization.reload).to be_reassessment_required
  end

  it "keeps the pause when the pinned lineage no longer matches the established chain" do
    pause_for_policy_rollback!
    FeatureFlags.enable!(:project_delegation, project: project)
    create(:issue, :pull_request, project: project, github_number: 43, parent_issue_id: issue.id)

    expect { described_class.call(authorization: authorization, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /lineage/)
    expect(authorization.reload).to be_reassessment_required
  end

  it "fails closed resuming a legacy authorization without canonical pinned evidence" do
    legacy = create(:bounded_delegated_action, account: account, project: project, issue: issue, created_by: user)
    legacy.require_reassessment!(reasons: [ :intent_revision ])

    expect { described_class.call(authorization: legacy, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /intent_revision/)
    expect(legacy.reload).to be_reassessment_required
  end

  it "rejects resume for an authorization that is no longer reassessment-required" do
    authorization

    expect { described_class.call(authorization: authorization, user: user, resolution: :resume) }
      .to raise_error(described_class::InvalidResolution, /no longer resolvable/)
  end

  it "lets an authorized actor stop a reassessment-required authorization" do
    pause_for_policy_rollback!

    expect(described_class.call(authorization: authorization, user: user, resolution: :stop)).to eq(:stopped)
    expect(authorization.reload).to be_revoked
  end

  it "denies resolution to an actor without the delegation permission" do
    pause_for_policy_rollback!
    other_user = create(:user, account: account)

    expect { described_class.call(authorization: authorization, user: other_user, resolution: :stop) }
      .to raise_error(described_class::PermissionDenied)
    expect(authorization.reload).to be_reassessment_required
  end
end
