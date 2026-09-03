# frozen_string_literal: true

require "rails_helper"

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
end
