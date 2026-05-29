# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::SeedData::Paid do
  it "returns the seeded style guide metadata" do
    result = described_class.call

    style_guide = StyleGuide.find(result.dig("style_guide", "id"))

    expect(result.fetch("style_guide")).to eq(
      "id" => style_guide.id,
      "name" => "Screenshot Style Guide"
    )
  end

  it "returns the seeded clarifying issue metadata" do
    result = described_class.call

    issue = Issue.find(result.dig("clarifying_issue", "id"))

    expect(result.fetch("clarifying_issue")).to eq(
      "id" => issue.id,
      "github_number" => 1964
    )
    expect(issue).to be_needs_input
  end

  it "returns seeded strategy review metadata" do
    result = described_class.call

    strategy = Strategy.find(result.dig("strategy", "id"))
    pending_strategy_version = StrategyVersion.find(result.dig("pending_strategy_version", "id"))

    expect(result.fetch("strategy")).to eq(
      "id" => strategy.id,
      "name" => "Screenshot Strategy"
    )
    expect(pending_strategy_version).to be_pending_review
    expect(pending_strategy_version.strategy).to eq(strategy)
  end

  it "returns seeded GitHub App installation metadata" do
    result = described_class.call

    installation = GithubInstallation.find(result.dig("github_installation", "id"))

    expect(result.fetch("github_installation")).to eq(
      "id" => installation.id,
      "account_login" => "paid"
    )
    expect(installation).to be_active
  end

  it "returns marketplace entry metadata for marketplace screenshot targets" do
    result = described_class.call

    marketplace_entry = MarketplaceEntry.find(result.dig("marketplace_entry", "id"))

    expect(result.fetch("marketplace_entry")).to eq(
      "id" => marketplace_entry.id,
      "name" => "Screenshot Catalog Entry"
    )
    expect(marketplace_entry.current_version).to have_attributes(version: 1)
  end
end
