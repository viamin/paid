# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::Resolver, :no_db do
  let(:initializer_path) { Rails.root.join("config/initializers/container_backend.rb") }
  let(:remote_backend) { instance_double(Containers::Backends::RemoteDocker, identifier: "worker-1", remote?: true) }
  let(:local_backend) { instance_double(Containers::Backends::LocalDocker, remote?: false) }

  around do |example|
    original_backend = ENV["CONTAINER_BACKEND"]
    original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
    example.run
  ensure
    ENV["CONTAINER_BACKEND"] = original_backend
    ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
  end

  before do
    allow(described_class).to receive(:reset!)
    allow(described_class).to receive(:register)
    allow(Containers::Backends::LocalDocker).to receive(:new).and_return(local_backend)
  end

  def run_initializer
    load initializer_path
    Rails.application.reloader.prepare!
  end

  it "warns when the remote backend is active without PAID_PROXY_EXTERNAL_URL" do
    ENV["CONTAINER_BACKEND"] = "remote"
    ENV.delete("PAID_PROXY_EXTERNAL_URL")

    allow(Containers::Backends::RemoteDocker).to receive(:from_env).and_return(remote_backend)
    allow(described_class).to receive(:for).with(:remote).and_return(remote_backend)

    expect(Rails.logger).to receive(:warn).with(
      "Remote Docker backend is active but PAID_PROXY_EXTERNAL_URL is not set; remote containers will be unable to reach the secrets proxy"
    )

    run_initializer
  end

  it "does not warn when the remote backend has an external proxy URL" do
    ENV["CONTAINER_BACKEND"] = "remote"
    ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

    allow(Containers::Backends::RemoteDocker).to receive(:from_env).and_return(remote_backend)
    allow(described_class).to receive(:for).with(:remote).and_return(remote_backend)

    expect(Rails.logger).not_to receive(:warn)

    run_initializer
  end
end
