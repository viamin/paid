# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  # @spec FEATURE-APPROVAL-001
  describe "#operating_mode" do
    it "defaults to standard so no project is silently enrolled" do
      expect(described_class.new.operating_mode).to eq("standard")
    end

    it "accepts the named human-led feature factory mode" do
      expect(build(:project, operating_mode: "human_led_feature_factory")).to be_valid
    end

    it "rejects unknown operating modes" do
      project = build(:project, operating_mode: "chaos_factory")

      expect(project).not_to be_valid
      expect(project.errors[:operating_mode]).to be_present
    end
  end

  describe "#human_led_feature_factory?" do
    it "is true only for the named mode" do
      expect(build(:project, operating_mode: "standard")).not_to be_human_led_feature_factory
      expect(build(:project, operating_mode: "human_led_feature_factory")).to be_human_led_feature_factory
    end
  end

  # @spec FEATURE-APPROVAL-005
  describe "leaving the human-led mode" do
    let(:project) do
      create(:project, operating_mode: "human_led_feature_factory", auto_pick_enabled: true)
    end
    let!(:issue) { create(:issue, :in_progress, project: project) }

    it "is a settings-only change that never enqueues or mutates work" do
      expect {
        project.update!(operating_mode: "standard")
      }.not_to change(AgentRun, :count)

      expect(project.reload.human_led_feature_factory?).to be false
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "does not release work when another profile resets the mode" do
      actor = create(:user, :owner, account: project.account)
      plan = Configuration::Profiles::Planner.call(
        profile: Configuration::Profiles::ManualOnLabel, project: project, actor: actor
      )
      Configuration::Profiles::Applier.call(plan: plan, project: project, actor: actor)

      expect(project.reload.operating_mode).to eq("standard")
      expect(AgentRun.count).to eq(0)
      expect(issue.reload.paid_state).to eq("in_progress")
    end
  end
end
