# frozen_string_literal: true

require "faraday/retry"

# @spec TEST-SUITE-016
# Keep the actual middleware and retry policy; replace only its external timer.
RSpec.shared_context "with recorded HTTP retry delays" do
  attr_reader :http_retry_delays

  before do
    @http_retry_delays = []
    allow(Faraday::Retry::Middleware).to receive(:new).and_wrap_original do |constructor, *args, **options|
      constructor.call(*args, **options).tap do |middleware|
        allow(middleware).to receive(:sleep) { |delay| http_retry_delays << delay }
      end
    end
  end
end
