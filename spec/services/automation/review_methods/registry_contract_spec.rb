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
    let(:plugin) { build_plugin(described_class, :copilot) }
    let(:expected_kind) { :bot }

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::PaidAgent do
    let(:plugin) { build_plugin(described_class, :paid_agent) }
    let(:expected_kind) { :agent }

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::Codex do
    let(:plugin) { build_plugin(described_class, :codex) }
    let(:expected_kind) { :comment_bot }

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::Manual do
    let(:plugin) { build_plugin(described_class, :manual) }
    let(:expected_kind) { :human }

    it_behaves_like "a ReviewMethods plugin"
  end

  describe Automation::ReviewMethods::CiAction do
    let(:plugin) do
      build_plugin(
        described_class, :ci_action,
        config: build_config(ci_action: { "enabled" => true, "action_name" => "claude-review" })
      )
    end
    let(:expected_kind) { :ci }

    it_behaves_like "a ReviewMethods plugin"
  end
  end
end
