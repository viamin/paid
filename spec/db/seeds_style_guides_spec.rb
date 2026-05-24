# frozen_string_literal: true

require "rails_helper"

module SeedsStyleGuidesSpec
  RUBY_GUIDE_NAMES = [
    "Ruby Conventions",
    "Service Objects (Servo)",
    "Rails Patterns",
    "Database and Migrations"
  ].freeze

  def load_style_guides_seed!
    silence_warnings do
      load Rails.root.join("db/seeds/style_guides.rb").to_s
    end
  end
end

RSpec.describe StyleGuide, type: :model do
  include ActiveJob::TestHelper
  include SeedsStyleGuidesSpec

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "seeds the Ruby-specific global guides as active language-scoped records" do
    load_style_guides_seed!

    guides = described_class.global.active.where(language: "ruby").order(:name)

    expect(guides.pluck(:name)).to eq(SeedsStyleGuidesSpec::RUBY_GUIDE_NAMES.sort)
  end

  it "is idempotent when re-run" do
    load_style_guides_seed!
    total_seeded = Seeds::StyleGuides::GUIDES.size

    described_class.global.update_all(compressed_content: "compressed", compression_metadata: {})
    clear_enqueued_jobs

    expect {
      load_style_guides_seed!
    }.not_to change(described_class.global, :count)

    expect(described_class.global.count).to eq(total_seeded)
    expect(enqueued_jobs).to be_empty
  end

  it "enqueues compression when raw_content changes on an existing seeded guide" do
    load_style_guides_seed!

    guide = described_class.global.find_by!(name: "Ruby Conventions")
    guide.update_columns(
      raw_content: "outdated content",
      compressed_content: "compressed",
      compression_metadata: {}
    )

    clear_enqueued_jobs

    expect {
      load_style_guides_seed!
    }.to have_enqueued_job(StyleGuideCompressionJob).with(guide.id)
  end
end
