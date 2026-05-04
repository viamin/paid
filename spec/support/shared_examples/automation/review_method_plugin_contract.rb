# frozen_string_literal: true

# Shared examples verifying that a concrete ReviewMethods plugin
# satisfies the Base contract. Every plugin (copilot, paid_agent,
# codex, ci_action, manual) should include this group.
#
# Expected `let` bindings:
#
#   plugin        — an instance of the plugin class under test
#   expected_kind — the Symbol kind the plugin must report
#
RSpec.shared_examples "a ReviewMethods plugin" do
  it "is a subclass of Automation::ReviewMethods::Base" do
    expect(plugin).to be_a(Automation::ReviewMethods::Base)
  end

  describe "#kind" do
    it "returns the expected symbol" do
      expect(plugin.kind).to eq(expected_kind)
    end

    it "returns a symbol" do
      expect(plugin.kind).to be_a(Symbol)
    end
  end

  describe "#name" do
    it "returns a symbol" do
      expect(plugin.name).to be_a(Symbol)
    end
  end

  describe "#evaluate" do
    it "returns an Automation::Strategies::AutoReview::Outcome" do
      result = plugin.evaluate

      expect(result).to be_a(Automation::Strategies::AutoReview::Outcome)
      expect(Automation::Strategies::AutoReview::Outcome::STATES).to include(result.state)
    end
  end

  describe "#decision" do
    it "returns nil or an Automation::Decision" do
      result = plugin.decision

      if result
        expect(result).to be_a(Automation::Decision)
      else
        expect(result).to be_nil
      end
    end
  end

  describe "#blocking_by_default?" do
    it "returns a boolean" do
      expect(plugin.blocking_by_default?).to be(true).or be(false)
    end
  end
end
