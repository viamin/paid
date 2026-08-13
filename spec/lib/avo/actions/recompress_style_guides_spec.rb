# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::Actions::RecompressStyleGuides do
  include ActiveJob::TestHelper

  let(:current_user) { Struct.new(:id, :email).new(7, "operator@example.com") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: true) }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(Rails).to receive(:logger).and_return(logger)
  end

  it "enqueues recompression for a single style guide and logs it" do
    style_guide = create(:style_guide, :global)

    action = described_class.new.handle(query: [ style_guide ], fields: {}, current_user:, resource: nil)

    expect(action.response[:messages]).to include(
      hash_including(type: :success, body: "Queued recompression for 1 style guide.")
    )
    expect(enqueued_jobs.last).to include(
      job: StyleGuideCompressionJob,
      args: [ style_guide.id ]
    )
    expect(logger).to have_received(:info).with(hash_including(
      message: "style_guides.compression_enqueued",
      style_guide_id: style_guide.id,
      source: "operator_console",
      actor_user_id: current_user.id,
      actor_user_email: current_user.email
    ))
  end

  it "supports bulk recompression" do
    style_guides = create_list(:style_guide, 2, :global)

    action = described_class.new.handle(query: style_guides, fields: {}, current_user:, resource: nil)

    expect(action.response[:messages]).to include(
      hash_including(type: :success, body: "Queued recompression for 2 style guides.")
    )
    expect(enqueued_jobs.last(2).map { |job| job[:args].first }).to match_array(style_guides.map(&:id))
  end
end
