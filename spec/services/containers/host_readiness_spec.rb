# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HostReadiness, :no_db do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    example.run
  ensure
    Rails.cache = original_cache
  end

  let(:image) { "paid-agent:latest" }
  let(:network) { instance_double(Docker::Network) }
  let(:agent_image) { instance_double(Docker::Image) }
  let(:local_backend) do
    instance_double(
      Containers::Backends::LocalDocker,
      identifier: "local",
      remote?: false,
      supports_host_paths?: true
    )
  end
  let(:remote_backend) do
    instance_double(
      Containers::Backends::RemoteDocker,
      identifier: "worker-1",
      remote?: true,
      supports_host_paths?: false
    )
  end

  before do
    allow(local_backend).to receive_messages(
      ping: "OK",
      system_info: { "Architecture" => "aarch64" }
    )
    allow(local_backend).to receive(:get_network).with(NetworkPolicy::NETWORK_NAME).and_return(network)
    allow(local_backend).to receive(:get_network).with(NetworkPolicy::INFRA_NETWORK_NAME).and_return(network)
    allow(local_backend).to receive(:get_image).with(image).and_return(agent_image)

    allow(remote_backend).to receive_messages(
      ping: "OK",
      system_info: { "Architecture" => "x86_64" }
    )
    allow(remote_backend).to receive(:get_network).with(NetworkPolicy::NETWORK_NAME).and_return(network)
    allow(remote_backend).to receive(:get_network).with(NetworkPolicy::INFRA_NETWORK_NAME).and_return(network)
    allow(remote_backend).to receive(:get_image).with(image).and_return(agent_image)
    allow(Net::HTTP).to receive(:start).and_return(Net::HTTPOK.new("1.1", "200", "OK"))
    allow(ENV).to receive(:[]).and_call_original
  end

  def call(backends:, requirements: nil, force_refresh: false)
    described_class.call(backends: backends, image: image, requirements: requirements, force_refresh: force_refresh)
  end

  def stub_http_get(response)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:get).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    http
  end

  it "returns healthy readiness for local Docker" do
    result = call(backends: [ local_backend ]).fetch(local_backend)

    expect(result[:healthy]).to be(true)
    expect(result[:failing_check]).to be_nil
    expect(result[:checks]).to include(hash_including(name: "docker_ping", healthy: true))
    expect(result[:checks]).to include(hash_including(name: "docker_image", healthy: true))
    expect(result[:checks]).to include(hash_including(name: "proxy_callback", healthy: true))
  end

  it "returns healthy readiness for remote Docker when networks, image, TLS, and callback are ready" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000")

    result = call(backends: [ remote_backend ]).fetch(remote_backend)

    expect(result[:healthy]).to be(true)
    expect(result[:failing_check]).to be_nil
    expect(result[:checks]).to include(hash_including(name: "proxy_callback", healthy: true))
    expect(result[:checks]).to include(hash_including(name: "docker_architecture", healthy: true))
  end

  it "reports proxy callback as unhealthy when liveness returns a non-success status" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000")
    allow(Net::HTTP).to receive(:start).and_return(Net::HTTPNotFound.new("1.1", "404", "Not Found"))

    result = call(backends: [ remote_backend ], force_refresh: true).fetch(remote_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:failing_check]).to eq("proxy_callback")
    expect(result[:remediation_hint]).to include("/health/liveness")
  end

  it "requests the liveness path when PAID_PROXY_EXTERNAL_URL has no path prefix" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000")
    yielded_http = stub_http_get(Net::HTTPOK.new("1.1", "200", "OK"))

    call(backends: [ remote_backend ], force_refresh: true).fetch(remote_backend)

    expect(yielded_http).to have_received(:get).with("/health/liveness")
  end

  it "preserves a path prefix in PAID_PROXY_EXTERNAL_URL when checking liveness" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000/paid")
    yielded_http = stub_http_get(Net::HTTPOK.new("1.1", "200", "OK"))

    call(backends: [ remote_backend ], force_refresh: true).fetch(remote_backend)

    expect(yielded_http).to have_received(:get).with("/paid/health/liveness")
  end

  it "reports a missing network with the failing check name" do
    allow(local_backend).to receive(:get_network).with(NetworkPolicy::INFRA_NETWORK_NAME)
      .and_raise(Docker::Error::NotFoundError.new("missing"))

    result = call(backends: [ local_backend ], force_refresh: true).fetch(local_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:failing_check]).to eq("docker_network:paid_internal")
    expect(result[:remediation_hint]).to include("paid_internal")
  end

  it "reports a missing image distinctly" do
    allow(local_backend).to receive(:get_image).with(image)
      .and_raise(Docker::Error::NotFoundError.new("missing image"))

    result = call(backends: [ local_backend ], force_refresh: true).fetch(local_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:failing_check]).to eq("docker_image")
    expect(result[:remediation_hint]).to include(image)
  end

  it "classifies bad remote TLS distinctly" do
    allow(remote_backend).to receive(:ping).and_raise(StandardError, "SSL_connect certificate verify failed")

    result = call(backends: [ remote_backend ], force_refresh: true).fetch(remote_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:failing_check]).to eq("docker_tls")
    expect(result[:remediation_hint]).to include("TLS client certificate")
  end

  it "reports missing proxy callback configuration distinctly for a remote host" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return(nil)
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL").and_return(nil)

    result = call(backends: [ remote_backend ], force_refresh: true).fetch(remote_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:failing_check]).to eq("proxy_callback")
    expect(result[:remediation_hint]).to include("PAID_PROXY_EXTERNAL_URL")
  end

  it "caches readiness independently per host" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000")

    first = call(backends: [ local_backend, remote_backend ])
    allow(local_backend).to receive(:ping).and_raise("should not be called again")
    allow(remote_backend).to receive(:ping).and_raise("should not be called again")
    second = call(backends: [ local_backend, remote_backend ])

    expect(first.fetch(local_backend)[:checked_at]).to eq(second.fetch(local_backend)[:checked_at])
    expect(first.fetch(remote_backend)[:checked_at]).to eq(second.fetch(remote_backend)[:checked_at])
  end

  it "evaluates selected-run compatibility independently from the cached host checks" do
    allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL_WORKER_1").and_return("http://paid.example:3000")
    requirements = described_class::Requirements.new(
      host_paths_required: true,
      subscription_auth_source: Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "codex",
        auth_mode: :host_forwarded
      )
    )

    result = call(backends: [ remote_backend ], requirements: requirements).fetch(remote_backend)

    expect(result[:healthy]).to be(false)
    expect(result[:capability_compatibility]).to include(
      eligible: false,
      check: "selected_run_capability",
      reason: "requires_host_bind_mount"
    )
  end
end
