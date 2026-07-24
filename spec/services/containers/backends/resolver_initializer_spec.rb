# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::Resolver, :no_db do
  let(:initializer_path) { Rails.root.join("config/initializers/container_backend.rb") }
  let(:remote_backend) { instance_double(Containers::Backends::RemoteDocker, identifier: "worker-1", remote?: true) }
  let(:local_backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local", remote?: false) }
  let(:qnap_backend) { instance_double(Containers::Backends::LocalDocker, identifier: "qnap", remote?: false) }
  let(:multi_host_registry) do
    Containers::HostRegistry::Registry.new(
      default_host: "qnap",
      fallback_policy: Containers::HostRegistry::FALLBACK_DISABLED,
      hosts: [
        Containers::HostRegistry::HostDefinition.new(
          identifier: "qnap",
          backend: qnap_backend,
          max_concurrent_runs: 2,
          fallback_enabled: true
        ),
        Containers::HostRegistry::HostDefinition.new(
          identifier: "worker-1",
          backend: remote_backend,
          max_concurrent_runs: 4,
          fallback_enabled: true
        )
      ]
    )
  end

  around do |example|
    original_backend = ENV["CONTAINER_BACKEND"]
    original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
    original_config_backend = Rails.application.config.x.container_backend
    example.run
  ensure
    ENV["CONTAINER_BACKEND"] = original_backend
    ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
    Rails.application.config.x.container_backend = original_config_backend
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

  it "warns in multi-host mode when any configured host is remote without PAID_PROXY_EXTERNAL_URL" do
    ENV["CONTAINER_BACKEND"] = "multi"
    ENV.delete("PAID_PROXY_EXTERNAL_URL")

    allow(Containers::HostRegistry).to receive(:load).and_return(multi_host_registry)
    allow(described_class).to receive(:for).with(:qnap).and_return(qnap_backend)

    expect(Rails.logger).to receive(:warn).with(
      "Remote Docker backend is active but PAID_PROXY_EXTERNAL_URL is not set; remote containers will be unable to reach the secrets proxy"
    )

    run_initializer
  end
end
