# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Registry do
  context "with plugin contract verification" do
  def build_config(**methods)
    method_hashes = Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |name, h|
      h[name.to_s] = methods[name] || { "enabled" => false }
    end
    review_settings = Automation::Configuration::ReviewSettings.from_hash(
      "enabled" => true,
      "methods" => method_hashes
    )
    Automation::Configuration::AutoReview.new(review_settings: review_settings)
  end

  def build_signals(triggers: [])
    Automation::Strategies::AutoReview::Signals.from_scan(
      issue_id: 1,
      pr_number: 50,
      phase: "draft",
      triggers: triggers
    )
  end

  def build_plugin(plugin_class, method_name, config: nil, triggers: [])
    config ||= build_config(method_name => { "enabled" => true })
    signals = build_signals(triggers: triggers)
    plugin_class.new(
      method: config.method_for(method_name),
      config: config,
      signals: signals
    )
  end

  describe Automation::ReviewMethods::Copilot do
    let(:method_name) { :copilot }
    let(:resolved_class) { Automation::ReviewMethods::Registry.resolve(method_name) }
    let(:plugin) { build_plugin(resolved_class, method_name) }
    let(:expected_kind) { :bot }

    it "resolves :copilot through the registry defaults" do
      expect(resolved_class).to eq(described_class)
    end

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::PaidAgent do
    let(:method_name) { :paid_agent }
    let(:resolved_class) { Automation::ReviewMethods::Registry.resolve(method_name) }
    let(:plugin) { build_plugin(resolved_class, method_name) }
    let(:expected_kind) { :agent }

    it "resolves :paid_agent through the registry defaults" do
      expect(resolved_class).to eq(described_class)
    end

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::Codex do
    let(:method_name) { :codex }
    let(:resolved_class) { Automation::ReviewMethods::Registry.resolve(method_name) }
    let(:plugin) { build_plugin(resolved_class, method_name) }
    let(:expected_kind) { :comment_bot }

    it "resolves :codex through the registry defaults" do
      expect(resolved_class).to eq(described_class)
    end

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::Manual do
    let(:method_name) { :manual }
    let(:resolved_class) { Automation::ReviewMethods::Registry.resolve(method_name) }
    let(:plugin) { build_plugin(resolved_class, method_name) }
    let(:expected_kind) { :human }

    it "resolves :manual through the registry defaults" do
      expect(resolved_class).to eq(described_class)
    end

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::CiAction do
    let(:method_name) { :ci_action }
    let(:resolved_class) { Automation::ReviewMethods::Registry.resolve(method_name) }
    let(:plugin) do
      build_plugin(
        resolved_class, method_name,
        config: build_config(ci_action: { "enabled" => true, "action_name" => "claude-review" })
      )
    end
    let(:expected_kind) { :ci }

    it "resolves :ci_action through the registry defaults" do
      expect(resolved_class).to eq(described_class)
    end

    it_behaves_like "a ReviewMethods plugin"
  end
  end
end
