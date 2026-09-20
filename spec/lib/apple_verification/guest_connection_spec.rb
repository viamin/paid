# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::GuestConnection do # @spec APPLE-VERIFY-005
  let(:transport) { instance_spy(described_class::HttpTransport) }
  let(:image) { create(:apple_verification_image, :active) }
  let(:manifest) { { "version" => 1, "operations" => [] } }

  it "sends the selected image and protocol manifest to the authenticated guest executor" do
    allow(transport).to receive(:post).and_return(response(code: 200, body: { "operations" => [] }.to_json))

    result = described_class.new(token: "guest-token", transport:).dispatch!(image:, manifest:)

    expect(result).to eq([])
    expect(transport).to have_received(:post).with(
      uri: URI("https://apple-executor.example.test/v1/jobs"),
      headers: { "Authorization" => "Bearer guest-token", "Content-Type" => "application/json" },
      body: { "image_digest" => image.digest, "manifest" => manifest }.to_json
    )
  end

  it "rejects an unauthenticated executor response" do
    allow(transport).to receive(:post).and_return(response(code: 401, body: ""))

    expect { described_class.new(token: "guest-token", transport:).dispatch!(image:, manifest:) }
      .to raise_error(described_class::AuthenticationError)
  end

  it "rejects a missing executor credential before sending work" do
    connection = described_class.new(token: nil, transport:)

    expect { connection.dispatch!(image:, manifest:) }.to raise_error(described_class::ConfigurationError)
    expect(transport).not_to have_received(:post)
  end

  it "rejects a malformed executor result" do
    allow(transport).to receive(:post).and_return(response(code: 200, body: "{}"))

    expect { described_class.new(token: "guest-token", transport:).dispatch!(image:, manifest:) }
      .to raise_error(described_class::DispatchError, /operations/)
  end

  def response(code:, body:)
    described_class::Response.new(code:, body:)
  end
end
