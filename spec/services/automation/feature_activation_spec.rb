# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec AUTOMATION-ACTIVATION-003 @spec AUTOMATION-ACTIVATION-004 @spec AUTOMATION-ACTIVATION-005 @spec AUTOMATION-ACTIVATION-006
RSpec.describe Automation::FeatureActivation do
  describe ".issue_auto_pick_trigger" do
    let(:project) { create(:project, auto_pick_enabled: false, auto_enhance_enabled: false) }
    let(:issue) { create(:issue, project: project, labels: [ project.automation_label_name ], paid_state: "new") }

    before do
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(false)
    end

    it "returns the trusted auto-pick activation label" do
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?)
        .with(project, issue, project.automation_label_name).and_return(true)

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to eq(project.automation_label_name)
    end

    it "lets skip labels beat the catchall activation" do
      issue.update!(labels: [ "planning", project.feature_activation_label_for("paid_in_full") ])
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(true)

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_nil
    end

    it "ignores an untrusted activation label even when the issue creator is trusted" do
      issue.update!(github_creator_login: "viamin")

      expect(described_class.issue_auto_pick_trigger(project:, issue:)).to be_nil
    end
  end

  describe ".issue_tdd_mode" do
    let(:project) { create(:project, tdd_mode: "off") }
    let(:issue) do
      create(:issue, project: project, labels: [
        project.feature_activation_label_for("paid_in_full"),
        project.feature_activation_label_for("tdd_auto")
      ])
    end

    it "lets a specific TDD label beat the paid-in-full catchall" do
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?) do |_project, _issue, label|
        [ project.feature_activation_label_for("paid_in_full"), project.feature_activation_label_for("tdd_auto") ].include?(label)
      end

      expect(described_class.issue_tdd_mode(project:, issue:)).to eq("non_strict")
    end

    # @spec AUTOMATION-ACTIVATION-005
    it "preserves the project-level mode for issue-less runs" do
      project.update!(tdd_mode: "strict")

      expect(described_class.issue_tdd_mode(project:, issue: nil)).to eq("strict")
    end

    # @spec AUTOMATION-ACTIVATION-005
    it "returns off for issue-less runs on label-driven projects" do
      expect(described_class.issue_tdd_mode(project:, issue: nil)).to eq("off")
    end
  end

  describe ".pull_request_feature_enabled?" do
    let(:project) { create(:project, auto_merge_mode: "off") }
    let(:issue) { create(:issue, project: project, labels: [ project.feature_activation_label_for("paid_in_full") ]) }
    let(:pull_request) { create(:issue, :pull_request, project: project, parent_issue: issue, labels: []) }

    it "does not let paid-in-full grant auto-merge by itself" do
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(true)

      expect(described_class.pull_request_feature_enabled?(project:, pull_request:, feature: "auto_merge")).to be(false)
    end
  end

  describe ".any_pull_request_feature_enabled?" do
    let(:project) { create(:project, auto_scan_prs: false) }

    it "short-circuits without trust checks when no PR is labeled" do
      create(:issue, :pull_request, project: project, github_state: "open", labels: [])

      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?)

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(false)
      expect(Automation::LabelPolicy).not_to have_received(:trusted_user_added_label?)
    end

    it "returns true for a PR with a trusted activation label" do
      pull_request = create(:issue, :pull_request, project: project, github_state: "open",
        labels: [ project.feature_activation_label_for("auto_scan_prs") ])
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?)
        .with(project, pull_request, project.feature_activation_label_for("auto_scan_prs")).and_return(true)

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(true)
    end

    it "returns true via a trusted catchall parent without a PR label" do
      parent = create(:issue, project: project,
        labels: [ project.feature_activation_label_for("paid_in_full") ])
      create(:issue, :pull_request, project: project, github_state: "open", parent_issue: parent, labels: [])
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(true)

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_scan_prs")).to be(true)
    end

    it "does not consult the catchall for auto_merge" do
      parent = create(:issue, project: project,
        labels: [ project.feature_activation_label_for("paid_in_full") ])
      create(:issue, :pull_request, project: project, github_state: "open", parent_issue: parent, labels: [])
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?).and_return(true)

      expect(described_class.any_pull_request_feature_enabled?(project:, feature: "auto_merge")).to be(false)
    end
  end

  describe "Automation::LabelPolicy event caching" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project, labels: [ "paid-automation" ]) }
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(project).to receive(:client).and_return(github_client)
      allow(github_client).to receive(:issue_events).and_return([
        OpenStruct.new(event: "labeled", actor: OpenStruct.new(login: "viamin"),
          label: OpenStruct.new(name: "paid-automation"), created_at: 1.hour.ago)
      ])
    end

    it "fetches the label events once per record across label checks" do
      Automation::LabelPolicy.clear_label_event_cache!

      expect(Automation::LabelPolicy.trusted_user_added_label?(project, issue, "paid-automation")).to be(true)
      expect(Automation::LabelPolicy.trusted_user_added_label?(project, issue, "paid-automation")).to be(true)

      expect(github_client).to have_received(:issue_events).once
    end
  end
end
