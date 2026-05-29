# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Integrations::GithubCopilot do
  it "exposes key and display_name" do
    expect(described_class.key).to eq("github_copilot")
    expect(described_class.display_name).to eq("GitHub Copilot")
  end

  it "returns an ingestion protocol" do
    expect(described_class.ingestion_protocol).to eq(:webhook)
  end

  it "lists supported features" do
    expect(described_class.supported_features).to include(:external_execution_ingestion, :outcome_comparison)
  end

  it "returns an agent type key" do
    expect(described_class.agent_type_key).to eq("copilot")
  end

  it "normalizes external metadata" do
    metadata = described_class.normalize_external_metadata({
      "session_type" => "inline",
      "editor" => "vscode",
      "language" => "ruby",
      "metrics" => { "suggestions_accepted" => 42 }
    })
    expect(metadata["session_type"]).to eq("inline")
    expect(metadata["suggestions_accepted"]).to eq(42)
  end
end
