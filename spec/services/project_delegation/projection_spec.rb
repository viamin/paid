# frozen_string_literal: true

require "rails_helper"

# RDR-080 "One policy contract": the shared delegation projection every
# surface reads. Each authorization row carries the effective policy
# Automation::EffectivePolicy computes for its own work item, so no surface
# infers authority from a label, stale approval, queue state, or UI state.
#
# @spec PROJECT-DELEGATION-005
RSpec.describe ProjectDelegation::Projection do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:other_issue) { create(:issue, project:) }

  def authorize(action:, work_item: issue)
    create(:bounded_delegated_action,
      project: work_item.project,
      issue: work_item,
      action: action,
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: action, acceptance_refs: [ "AC-1" ],
        stop_before_phase: Automation::DelegatedActionAdmission::STOP_BEFORE_PHASES.fetch(action)
      ))
  end

  def configure_phases(phases)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  describe "default-off gate" do
    it "defines the project_delegation flag default-off" do # @spec PROJECT-DELEGATION-005
      definition = FeatureFlags.definition(described_class::FLAG)

      expect(definition.name).to eq(:project_delegation)
      expect(definition.rollout_plan).to include("Default-off")
    end

    it "is disabled for a project that never opted in and exposes no authorizations" do # @spec PROJECT-DELEGATION-005
      authorize(action: "review")

      result = described_class.call(project:)

      expect(result.enabled).to be(false)
      expect(result.authorizations).to be_empty
    end

    it "is disabled while only the automation_phases rollout is on" do # @spec PROJECT-DELEGATION-005
      FeatureFlags.enable!(:automation_phases, project:)

      expect(described_class.enabled?(project)).to be(false)
    end
  end

  describe "effective-policy contract" do
    before do
      FeatureFlags.enable!(:automation_phases, project:)
      FeatureFlags.enable!(described_class::FLAG, project:)
    end

    it "reads each authorization's authority through Automation::EffectivePolicy" do # @spec PROJECT-DELEGATION-005
      authorize(action: "review")
      configure_phases({ "coding" => true })

      result = described_class.call(project:)
      authorization = result.authorizations.first

      expect(result.authorizations.size).to eq(1)
      expect(authorization.phase).to eq(Automation::DelegatedActionAdmission::ACTION_PHASES.fetch("review"))
      expect(authorization.effective_policy).to include(permitted: true, source: :project_defaults)
    end

    it "attributes authority to the legacy policy while the phase rollout is off" do # @spec PROJECT-DELEGATION-005
      FeatureFlags.disable!(:automation_phases, project:)
      authorize(action: "review")

      result = described_class.call(project:)

      expect(result.phase_model_enabled).to be(false)
      expect(result.authorizations.first.effective_policy).to include(permitted: true, source: :legacy_policy)
    end

    it "reports a continuation grant as the authority that covers the work item" do # @spec PROJECT-DELEGATION-005
      configure_phases({ "coding" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      authorize(action: "review")

      authorization = described_class.call(project:).authorizations.first

      expect(authorization.effective_policy).to include(permitted: true, source: :continuation_grant)
    end

    it "reports a blocked phase-disabled decision instead of implying authority" do # @spec PROJECT-DELEGATION-005
      configure_phases({ "coding" => false })
      authorize(action: "review")

      authorization = described_class.call(project:).authorizations.first

      expect(authorization.effective_policy).to include(permitted: false, source: nil, reason: :phase_disabled)
    end

    it "matches the decision EffectivePolicy returns for the same work item" do # @spec PROJECT-DELEGATION-005
      configure_phases({ "coding" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      authorize(action: "review")

      authorization = described_class.call(project:).authorizations.first
      direct = Automation::EffectivePolicy.call(
        project:, phase: authorization.phase, work_item: issue, trigger: :automatic
      )

      expect(authorization.effective_policy).to eq(direct.to_h)
    end
  end

  describe "governing authorization rows" do
    before do
      FeatureFlags.enable!(:automation_phases, project:)
      FeatureFlags.enable!(described_class::FLAG, project:)
    end

    it "projects only the newest authorization per work item and action" do # @spec PROJECT-DELEGATION-005
      superseded = authorize(action: "review")
      authorize(action: "review")

      rows = described_class.call(project:).authorizations

      expect(rows.size).to eq(1)
      expect(rows.first.authorization_id).not_to eq(superseded.id)
    end

    it "keeps one row per action when a work item holds several delegations" do
      authorize(action: "review")
      authorize(action: "repair")

      expect(described_class.call(project:).authorizations.size).to eq(2)
    end

    it "selects governing rows in SQL so a capped history cannot hide one" do
      authorize(action: "review")
      other = authorize(action: "review", work_item: other_issue)

      queries = capture_queries { described_class.call(project:) }

      expect(queries.grep(/DISTINCT ON/i).size).to eq(1)
      expect(described_class.call(project:).authorizations.map(&:authorization_id)).to include(other.id)
    end

    it "scopes to one work item for run-detail surfaces" do # @spec PROJECT-DELEGATION-005
      authorize(action: "review")
      authorize(action: "review", work_item: other_issue)

      rows = described_class.call(project:, issue: other_issue).authorizations

      expect(rows.size).to eq(1)
      expect(rows.first.issue_id).to eq(other_issue.id)
    end
  end

  describe "batched resolution" do
    before do
      FeatureFlags.enable!(:automation_phases, project:)
      FeatureFlags.enable!(described_class::FLAG, project:)
    end

    it "does not grow grant queries with the authorization count" do # @spec PROJECT-DELEGATION-005
      authorize(action: "review")

      single = capture_queries { described_class.call(project:) }
        .grep(/FROM ["']?work_item_continuation_grants/i).size

      authorize(action: "repair")
      authorize(action: "review", work_item: other_issue)

      several = capture_queries { described_class.call(project:) }
        .grep(/FROM ["']?work_item_continuation_grants/i).size

      expect(several).to eq(single)
      expect(several).to eq(1)
    end
  end

  describe "payload" do
    it "serializes every authorization with its own authority" do # @spec PROJECT-DELEGATION-005
      FeatureFlags.enable!(described_class::FLAG, project:)
      authorization = authorize(action: "review")

      payload = described_class.call(project:).to_h

      expect(payload).to include(enabled: true, phase_model_enabled: false)
      expect(payload.fetch(:authorizations)).to contain_exactly(
        hash_including(
          authorization_id: authorization.id,
          action: "review",
          issue_id: issue.id,
          effective_policy: hash_including(:permitted, :source, :reason)
        )
      )
    end
  end
end
