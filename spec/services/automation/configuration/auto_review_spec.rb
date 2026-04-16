# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Configuration::AutoReview do
  def build_config(enabled: true, **methods)
    method_hashes = Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |name, h|
      h[name.to_s] = methods[name] || { "enabled" => false }
    end
    described_class.new(
      review_settings: Automation::Configuration::ReviewSettings.from_hash(
        "enabled" => enabled,
        "methods" => method_hashes
      )
    )
  end

  describe "#bot_request_login" do
    it "returns nil when the review toggle is off" do
      config = build_config(enabled: false, copilot: { "enabled" => true })

      expect(config.bot_request_login).to be_nil
    end

    it "prefers copilot when both copilot and codex are enabled" do
      config = build_config(
        copilot: { "enabled" => true },
        codex: { "enabled" => true }
      )

      expect(config.bot_request_login).to eq("copilot")
    end

    it "falls back to codex when copilot is disabled" do
      config = build_config(codex: { "enabled" => true })

      expect(config.bot_request_login).to eq("chatgpt-codex-connector")
    end

    it "returns nil when no bot-backed method is enabled" do
      config = build_config(manual: { "enabled" => true, "reviewer_login" => "alice" })

      expect(config.bot_request_login).to be_nil
    end
  end

  describe "#bot_request_chain" do
    it "returns an empty array when the review toggle is off" do
      config = build_config(enabled: false, copilot: { "enabled" => true }, codex: { "enabled" => true })

      expect(config.bot_request_chain).to eq([])
    end

    it "returns an empty array when no bot-backed method is enabled" do
      config = build_config(manual: { "enabled" => true, "reviewer_login" => "alice" })

      expect(config.bot_request_chain).to eq([])
    end

    it "returns only the enabled bot, with copilot taking precedence" do
      copilot_only = build_config(copilot: { "enabled" => true })
      codex_only = build_config(codex: { "enabled" => true })

      expect(copilot_only.bot_request_chain).to eq([ "copilot" ])
      expect(codex_only.bot_request_chain).to eq([ "chatgpt-codex-connector" ])
    end

    it "returns the full ordered chain when both copilot and codex are enabled" do
      config = build_config(copilot: { "enabled" => true }, codex: { "enabled" => true })

      expect(config.bot_request_chain).to eq([ "copilot", "chatgpt-codex-connector" ])
    end

    it "keeps bot_request_login aligned with the chain head" do
      config = build_config(copilot: { "enabled" => true }, codex: { "enabled" => true })

      expect(config.bot_request_login).to eq(config.bot_request_chain.first)
    end
  end

  describe "#ordered_enabled_methods" do
    it "returns enabled methods in canonical order regardless of input order" do
      config = build_config(
        manual: { "enabled" => true, "reviewer_login" => "alice" },
        copilot: { "enabled" => true }
      )

      expect(config.ordered_enabled_methods.map(&:name)).to eq(%i[copilot manual])
    end

    it "is NOT gated by the review toggle (mirrors legacy Project#enabled_review_methods)" do
      config = build_config(enabled: false, copilot: { "enabled" => true })

      expect(config.ordered_enabled_methods.map(&:name)).to eq(%i[copilot])
    end
  end

  describe "#paid_agent_sole_method?" do
    it "returns true only when paid_agent is the sole enabled method and reviews are enabled" do
      config = build_config(paid_agent: { "enabled" => true })
      expect(config.paid_agent_sole_method?).to be true
    end

    it "returns false when another method is also enabled" do
      config = build_config(
        paid_agent: { "enabled" => true },
        copilot: { "enabled" => true }
      )
      expect(config.paid_agent_sole_method?).to be false
    end

    it "returns false when reviews are globally disabled" do
      config = build_config(enabled: false, paid_agent: { "enabled" => true })
      expect(config.paid_agent_sole_method?).to be false
    end
  end
end
