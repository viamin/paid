# frozen_string_literal: true

require "rails_helper"

# RDR-077 execution enforcement at the capability entry points: a disabled
# phase grants no standing authorization, and a trusted activation label
# cannot re-enable it.
#
# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-007
RSpec.describe Automation::FeatureActivation do
  let(:account) { create(:account) }
  let(:project) do
    create(:project, account:, auto_pick_enabled: false, auto_enhance_enabled: false,
      auto_merge_mode: "off", auto_scan_prs: false, auto_scan_security: false,
      auto_fix_merge_conflicts: false)
  end
  let(:issue) { create(:issue, project:, labels: [ project.feature_activation_label_for("paid_in_full") ]) }

  def configure(phases)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  before do
    allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(true)
    FeatureFlags.enable!(:automation_phases, project:)
  end

  describe "trusted activation labels" do
    it "cannot enable a disabled coding phase for auto-pick" do
      configure({ "coding" => false })

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_nil
    end

    it "cannot enable a disabled issue-preparation phase for auto-enhance" do
      configure({ "issue_preparation" => false })

      expect(described_class.issue_auto_enhance_enabled?(project:, issue:)).to be(false)
    end

    it "cannot enable a disabled merge phase for auto-merge" do
      configure({ "merge" => false })
      pull_request = create(:issue, :pull_request, project:)

      expect(described_class.human_pull_request_auto_merge_enabled?(project:, pull_request:)).to be(false)
    end

    it "keeps labels working once the phase is enabled" do
      configure({ "coding" => true })

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_present
    end
  end

  describe "continuation grants" do
    it "authorizes a disabled coding phase for the granted work item only" do
      configure({ "coding" => false, "merge" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      other_issue = create(:issue, project:)

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_present
      expect(described_class.issue_auto_pick_trigger(project:, issue: other_issue)).to be_nil
    end

    it "authorizes merge for a granted work item whose pull request is in the chain" do
      configure({ "coding" => false, "merge" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue,
        labels: [ project.feature_activation_label_for("auto_merge") ])

      expect(described_class.human_pull_request_auto_merge_enabled?(project:, pull_request:)).to be(true)
    end

    it "still requires the capability's own activation signal inside a granted phase" do
      configure({ "coding" => false, "merge" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue)

      expect(described_class.human_pull_request_auto_merge_enabled?(project:, pull_request:)).to be(false)
    end

    it "keeps a granted PR visible to project-wide scanning when its coding phase is disabled" do
      configure({ "coding" => false })
      project.update!(auto_scan_prs: true)
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue, github_state: "open")

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(false)

      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "coding")

      expect(described_class.pull_request_feature_enabled?(project:, pull_request:, feature: "auto_scan_prs")).to be(true)
      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(true)
    end

    it "finds a granted PR with a trusted scan label when project scanning is off" do
      configure({ "coding" => false })
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue, github_state: "open",
        labels: [ project.feature_activation_label_for("auto_scan_prs") ])
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "coding")

      expect(described_class.pull_request_feature_enabled?(project:, pull_request:, feature: "auto_scan_prs")).to be(true)
      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(true)

      grant.revoke!

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(false)
    end

    it "finds only a granted PR for merge when the merge phase is disabled" do
      configure({ "merge" => false })
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue, github_state: "open",
        labels: [ project.feature_activation_label_for("auto_merge") ])
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect(described_class.human_pull_request_auto_merge_enabled?(project:, pull_request:)).to be(true)
      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_merge")).to be(true)
    end
  end

  describe "while the rollout flag is off" do
    it "keeps the pre-existing label behavior" do
      FeatureFlags.disable!(:automation_phases, project:)
      configure({ "coding" => false })

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_present
    end
  end

  describe "bounded phase stops" do
    it "keeps auto-merge off for a lineage stopped before merge" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      configure({ "coding" => true, "merge" => true })
      project.update!(auto_merge_mode: "all")
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue)
      create(:bounded_delegated_action, project:, issue:,
        action: "review",
        evidence: Automation::DelegatedActionAdmission.admission_evidence(
          work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
        ))

      expect(described_class.pull_request_feature_enabled?(project:, pull_request:, feature: "auto_merge"))
        .to be(false)
      expect(described_class.human_pull_request_auto_merge_enabled?(project:, pull_request:)).to be(false)
    end

    it "keeps auto-merge available once a newer merge authorization supersedes the stop" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      configure({ "coding" => true, "merge" => true })
      project.update!(auto_merge_mode: "all")
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue)
      create(:bounded_delegated_action, project:, issue:,
        action: "review",
        evidence: Automation::DelegatedActionAdmission.admission_evidence(
          work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
        ))
      create(:bounded_delegated_action, project:, issue: pull_request,
        action: "merge",
        evidence: Automation::DelegatedActionAdmission.admission_evidence(
          work_item: pull_request, action: "merge", acceptance_refs: [ "AC-1" ],
          stop_before_phase: "release_deployment"
        ))

      expect(described_class.pull_request_feature_enabled?(project:, pull_request:, feature: "auto_merge"))
        .to be(true)
    end
  end
end
