# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Integrations::Cursor do
  it "exposes key and display_name" do
    expect(described_class.key).to eq("cursor")
    expect(described_class.display_name).to eq("Cursor")
  end

  it "normalizes external metadata with model and files" do
    metadata = described_class.normalize_external_metadata({
      "model" => "claude-3",
      "files_modified" => 5,
      "iterations" => 3,
      "metrics" => { "tokens_used" => 10000 }
    })
    expect(metadata["model"]).to eq("claude-3")
    expect(metadata["tokens_used"]).to eq(10000)
  end
end
