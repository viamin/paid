# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Renderer, :no_db do
  it "prefers a provider-native renderer when one exists" do
    entry = Struct.new(:provider_format, :entry_type, keyword_init: true)
      .new(provider_format: "canonical_v1", entry_type: "skill")
    version = Struct.new(:renderers, :canonical_artifact, keyword_init: true)
      .new(
      renderers: provider_renderers,
      canonical_artifact: canonical_artifact
    )

    rendered = described_class.call(entry:, version:, provider_key: "claude")

    expect(rendered).to eq(
      "provider" => "claude",
      "provider_format" => "claude_skill_v1",
      "attachment_strategy" => "prompt_append",
      "payload" => { "content" => "Claude-native instructions" }
    )
  end

  def provider_renderers
    {
      "claude" => {
        "provider_format" => "claude_skill_v1",
        "attachment_strategy" => "prompt_append",
        "content" => "Claude-native instructions"
      }
    }
  end

  def canonical_artifact
    {
      "attachment_strategy" => "prompt_append",
      "content" => "Canonical instructions"
    }
  end
end
