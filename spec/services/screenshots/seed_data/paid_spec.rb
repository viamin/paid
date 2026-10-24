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

  it "returns seeded Codex login session metadata for screenshot routes" do
    result = described_class.call

    login_session = CodexLoginSession.find(result.dig("codex_login_session", "id"))

    expect(result.fetch("codex_login_session")).to eq(
      "id" => login_session.id,
      "external_id" => login_session.external_id
    )
    expect(login_session).to be_awaiting_authorization
  end

  it "seeds a service container whose image is covered by the owner's allowlist" do # @spec TOOLCHAIN-PIN-027
    result = described_class.call

    service_container = ServiceContainer.find(result.dig("service_container", "id"))
    owner = User.find(result.dig("user", "id"))

    expect(service_container).to be_persisted
    expect(owner.settings.allowed_service_images).to include(service_container.image)
  end

  it "converges a service container seeded before the pin change on repeat runs" do # @spec TOOLCHAIN-PIN-027
    first_run = described_class.call
    ServiceContainer.find(first_run.dig("service_container", "id"))
                    .update_column(:image, "postgres:16")

    repeat_run = described_class.call

    service_container = ServiceContainer.find(repeat_run.dig("service_container", "id"))
    owner = User.find(repeat_run.dig("user", "id"))
    expect(service_container.id).to eq(first_run.dig("service_container", "id"))
    expect(service_container.image).to eq("postgres:16.15")
    expect(owner.settings.allowed_service_images).to include(service_container.image)
  end

  it "returns marketplace entry metadata for marketplace screenshot targets" do
    result = described_class.call

    marketplace_entry = MarketplaceEntry.find(result.dig("marketplace_entry", "id"))

    expect(result.fetch("marketplace_entry")).to eq(
      "id" => marketplace_entry.id,
      "name" => "Screenshot Catalog Entry"
    )
    expect(marketplace_entry.current_version).to have_attributes(version: 1)
    expect(marketplace_entry.extension_points).to eq([ "workflow_strategies", "prompts" ])
  end

  it "seeds a resumable solo shadow evaluation whose corpus manifest is present" do # @spec INTENT-CONFORMANCE-ROLLOUT-009
    result = described_class.call

    evaluation = IntentConformanceShadowEvaluation.find(result.dig("shadow_evaluation", "id"))
    maintainer = User.find(result.dig("user", "id"))

    expect(evaluation.project_id).to eq(result.dig("project", "id"))
    expect(evaluation).to be_labeling
    expect(evaluation.policy).to eq("solo")
    expect(evaluation.purpose).to eq("rdr-067-measured-rollout")
    expect(evaluation.solo_maintainer).to eq(maintainer)
    expect(evaluation.corpus.matches_recorded_digest?).to be(true)
    expect(evaluation.corpus.case_ids).to be_present
  end
end
