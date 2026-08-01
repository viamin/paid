# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::ReviewBotNotInstalled do
  let(:review_settings) do
    {
      "enabled" => true,
      "methods" => {
        "paid_agent" => { "enabled" => true }
      }
    }
  end

  let(:project) { build(:project, owner: "acme", repo: "widgets", review_settings: review_settings) }
  let(:token_provider) { instance_double(Github::ReviewBotInstallationToken) }

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    allow(Github::ReviewBotInstallationToken).to receive(:new)
      .with(repo_full_name: "acme/widgets")
      .and_return(token_provider)
  end

  it "returns no findings when the review bot is installed on the repository" do
    allow(token_provider).to receive(:installation_id).and_return(77)

    expect(described_class.call(project)).to eq([])
  end

  it "returns a warning when the review bot is missing from the repository" do
    allow(token_provider).to receive(:installation_id)
      .and_raise(Github::ReviewBotInstallationToken::NotInstalledError, "not installed")

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :warning,
        message: "Paid Agent review is enabled but the paid-code-reviewer GitHub App is not installed on this repository."
      )
    )
  end

  it "degrades gracefully on API errors" do
    allow(token_provider).to receive(:installation_id)
      .and_raise(Github::ReviewBotInstallationToken::Error, "GitHub request failed")

    expect(described_class.call(project)).to eq([])
  end

  context "when paid agent review is not enabled" do
    let(:review_settings) { { "enabled" => false } }

    it "returns no findings without contacting the review bot" do
      expect(described_class.call(project)).to eq([])
      expect(Github::ReviewBotInstallationToken).not_to have_received(:new)
    end
  end
end
