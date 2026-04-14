# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260414154102_backfill_legacy_review_max_rounds_defaults")

RSpec.describe BackfillLegacyReviewMaxRoundsDefaults, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:legacy_defaults_project) do
    create(:project, review_settings: {
      "enabled" => true,
      "methods" => {
        "copilot" => { "enabled" => true, "termination" => { "max_review_rounds" => 2 } },
        "paid_agent" => { "enabled" => true, "termination" => { "max_review_rounds" => 3 } },
        "codex" => { "enabled" => true, "termination" => { "max_review_rounds" => 2 } }
      }
    })
  end
  let(:custom_project) do
    create(:project, review_settings: {
      "enabled" => true,
      "methods" => {
        "copilot" => { "enabled" => true, "termination" => { "max_review_rounds" => 9 } },
        "paid_agent" => { "enabled" => true, "termination" => { "max_review_rounds" => 1 } },
        "codex" => { "enabled" => true, "termination" => { "max_review_rounds" => 20 } }
      }
    })
  end

  it "backfills persisted legacy default max review rounds without touching custom values" do
    legacy_defaults_project
    custom_project
    migration.up

    legacy_defaults_project.reload
    custom_project.reload

    expect(legacy_defaults_project.review_settings.dig("methods", "copilot", "termination", "max_review_rounds")).to eq(15)
    expect(legacy_defaults_project.review_settings.dig("methods", "paid_agent", "termination", "max_review_rounds")).to eq(15)
    expect(legacy_defaults_project.review_settings.dig("methods", "codex", "termination", "max_review_rounds")).to eq(15)

    expect(custom_project.review_settings.dig("methods", "copilot", "termination", "max_review_rounds")).to eq(9)
    expect(custom_project.review_settings.dig("methods", "paid_agent", "termination", "max_review_rounds")).to eq(1)
    expect(custom_project.review_settings.dig("methods", "codex", "termination", "max_review_rounds")).to eq(20)
  end
end
