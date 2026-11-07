# frozen_string_literal: true

RSpec.describe ProjectDelegation::ActionPermit do
  let(:project) { create(:project) }

  describe "#call" do
    it "returns a hash with delegation decision and metadata" do
      result = described_class.call(
        project:,
        action_class: "implementation_choice"
      )

      expect(result).to include(
        :delegated,
        :reason,
        :posture,
        :action_enabled
      )
    end
  end

  describe "#delegated?" do
    context "when delegation is disabled (feature flag off)" do
      it "returns false for any action" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.delegated?).to be(false)
      end
    end

    context "when posture is conservative" do
      before do
        project.update!(delegation_posture: "conservative")
      end

      it "returns false because conservative does not delegate" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.delegated?).to be(false)
      end
    end

    context "when posture is bounded_delivery but action is not enabled" do
      before do
        project.update!(
          delegation_posture: "bounded_delivery",
          delegation_enabled_actions: {}
        )
      end

      it "returns false for the action" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.delegated?).to be(false)
      end
    end

    context "when posture is bounded_delivery and action is enabled" do
      before do
        project.update!(
          delegation_posture: "bounded_delivery",
          delegation_enabled_actions: { "implementation_choice" => true }
        )
      end

      it "would return true if delegation were enabled" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        # Currently returns false because delegation_enabled? is false
        expect(permit.delegated?).to be(false)
      end
    end
  end

  describe "#action_enabled?" do
    context "when the action is in enabled_actions" do
      before do
        project.update!(
          delegation_enabled_actions: { "implementation_choice" => true }
        )
      end

      it "returns true" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.action_enabled?).to be(true)
      end
    end

    context "when the action is not in enabled_actions" do
      before do
        project.update!(
          delegation_enabled_actions: {}
        )
      end

      it "returns false" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.action_enabled?).to be(false)
      end
    end
  end

  describe "#reason" do
    context "when delegation is disabled" do
      it "returns :feature_disabled" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.send(:reason)).to eq(:feature_disabled)
      end
    end

    context "when posture is conservative" do
      before do
        project.update!(delegation_posture: "conservative")
      end

      it "returns :posture_conservative" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.send(:reason)).to eq(:posture_conservative)
      end
    end

    context "when action is not enabled" do
      before do
        project.update!(delegation_posture: "bounded_delivery")
      end

      it "returns :action_not_enabled" do
        permit = described_class.new(
          project:,
          action_class: "implementation_choice"
        )
        expect(permit.send(:reason)).to eq(:action_not_enabled)
      end
    end
  end

  describe ".call" do
    it "creates and calls an instance" do
      result = described_class.call(
        project:,
        action_class: "implementation_choice"
      )

      expect(result[:delegated]).to be(false)
      expect(result[:reason]).to eq(:feature_disabled)
    end
  end
end
