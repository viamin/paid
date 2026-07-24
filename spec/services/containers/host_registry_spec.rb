# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HostRegistry, :no_db do
  let(:env) do
    {
      "CONTAINER_BACKEND" => "multi",
      "CONTAINER_BACKENDS_CONFIG" => <<~YAML
        default_host: local
        fallback: first_healthy
        hosts:
          local:
            type: local
            concurrency:
              max_concurrent_runs: 2
          elguapo:
            type: remote
            host: tcp://100.113.201.1:2376
            tls:
              ca_file: /tmp/elguapo-ca.pem
              client_cert: /tmp/elguapo-cert.pem
              client_key: /tmp/elguapo-key.pem
            concurrency:
              max_concurrent_runs: 4
          aws-runner-1:
            type: remote
            host: tcp://10.0.10.25:2376
            tls:
              ca_file: /tmp/aws-ca.pem
              client_cert: /tmp/aws-cert.pem
              client_key: /tmp/aws-key.pem
            concurrency:
              max_concurrent_runs: 8
      YAML
    }
  end

  before do
    allow(Containers::Backends::LocalDocker).to receive(:new) do |identifier: "local"|
      instance_double(Containers::Backends::LocalDocker, identifier: identifier)
    end
    allow(Containers::Backends::RemoteDocker).to receive(:new) do |host:, identifier:, **_kwargs|
      instance_double(Containers::Backends::RemoteDocker, docker_url: host, identifier: identifier)
    end
  end

  it "loads independent per-host manual limits from multi-host config" do
    registry = described_class.load(env: env)

    expect(registry.default_host).to eq("local")
    expect(registry.fallback_policy).to eq("first_healthy")
    expect(registry.host_limit_for("local")).to eq(2)
    expect(registry.host_limit_for("elguapo")).to eq(4)
    expect(registry.host_limit_for("aws-runner-1")).to eq(8)
  end

  it "uses the configured identifier for local hosts" do
    env["CONTAINER_BACKENDS_CONFIG"] = <<~YAML
      default_host: qnap
      hosts:
        qnap:
          type: local
          concurrency:
            max_concurrent_runs: 3
    YAML

    registry = described_class.load(env: env)

    expect(Containers::Backends::LocalDocker).to have_received(:new).with(identifier: "qnap")
    expect(registry.default_host).to eq("qnap")
    expect(registry.host("qnap").backend.identifier).to eq("qnap")
    expect(registry.host_limit_for("qnap")).to eq(3)
  end
end
