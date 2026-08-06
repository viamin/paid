# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Registry do
  # @spec CONFIG-PROFILES-001
  it "enumerates the curated operating-mode profiles" do
    expect(described_class.names).to eq(%w[
      solo_automated
      team_reviewed
      observe_only
      manual_on_label
      cost_capped_automated
      quality_strict
    ])
  end

  it "returns profile modules from #all" do
    expect(described_class.all).to all(be_a(Module))
    expect(described_class.all.length).to eq(6)
  end

  it "finds a profile by name" do
    expect(described_class.find("team_reviewed")).to eq(Configuration::Profiles::TeamReviewed)
  end

  it "fetches a profile, raising on unknown names" do
    expect(described_class.fetch("observe_only")).to eq(Configuration::Profiles::ObserveOnly)
    expect { described_class.fetch("nope") }.to raise_error(ArgumentError, /Unknown configuration profile/)
  end

  it "reports existence" do
    expect(described_class).to exist("manual_on_label")
    expect(described_class).not_to exist("nope")
  end

  it "returns profile summaries keyed by profile_id" do
    expect(described_class.summaries).to include(
      include(
        profile_id: "solo_automated",
        name: "Solo Automated",
        description: Configuration::Profiles::SoloAutomated.description,
        clarifying_questions: Configuration::Profiles::SoloAutomated.clarifying_questions
      ),
      include(
        profile_id: "quality_strict",
        name: "Quality Strict"
      )
    )
  end
end
