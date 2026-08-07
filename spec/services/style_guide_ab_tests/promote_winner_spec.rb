# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideAbTests::PromoteWinner do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:style_guide) do
    create(
      :style_guide,
      account: account,
      project: nil,
      raw_content: "Control content",
      compressed_content: "compressed control",
      compression_metadata: {
        "compressed_at" => 1.day.ago.iso8601,
        "raw_content_sha256" => Digest::SHA256.hexdigest("Control content")
      }
    )
  end
  let(:original_version) { style_guide.current_version }
  let(:winning_version) do
    create(
      :style_guide_version,
      style_guide: style_guide,
      version: original_version.version + 1,
      raw_content: "Winning variant content",
      compressed_content: "winning compressed"
    )
  end
  let(:style_guide_ab_test) do
    create(
      :style_guide_ab_test,
      account: account,
      style_guide: style_guide,
      control_version: original_version,
      status: "completed",
      started_at: 1.day.ago,
      completed_at: Time.current
    )
  end
  let(:winner_variant) do
    create(
      :style_guide_ab_test_variant,
      style_guide_ab_test: style_guide_ab_test,
      style_guide_version: winning_version
    )
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
    style_guide_ab_test.update!(winner_variant: winner_variant)
  end

  # @spec STYLE-GUIDE-EVOLUTION-014
  it "promotes the winning version and mirrors its raw content onto the style guide row" do
    described_class.call(style_guide_ab_test: style_guide_ab_test)

    style_guide.reload

    expect(style_guide.current_version).to eq(winning_version)
    expect(style_guide.raw_content).to eq("Winning variant content")
    expect(style_guide.compressed_content).to be_nil
    expect(style_guide.compression_metadata).to include("raw_content_updated_at" => be_present)
  end

  it "enqueues recompression for the promoted guide" do
    described_class.call(style_guide_ab_test: style_guide_ab_test)

    expect(StyleGuideCompressionJob).to have_been_enqueued.with(style_guide.id)
  end

  it "raises when the test is not completed" do
    style_guide_ab_test.update!(status: "running", winner_variant: nil, completed_at: nil)

    expect { described_class.call(style_guide_ab_test: style_guide_ab_test) }
      .to raise_error(ArgumentError, /not completed/)
  end

  it "raises when there is no winner" do
    style_guide_ab_test.update!(winner_variant: nil)

    expect { described_class.call(style_guide_ab_test: style_guide_ab_test) }
      .to raise_error(ArgumentError, /no winner/)
  end
end
