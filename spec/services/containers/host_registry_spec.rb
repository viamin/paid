# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::HostRegistry, :no_db do
  let(:credentials_class) do
    Class.new do
      def dig(*); end
    end
  end
  let(:credentials) { instance_double(credentials_class, dig: nil) }
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
    allow(Rails.application).to receive(:credentials).and_return(credentials)
    allow(Containers::Backends::LocalDocker).to receive(:new) do |identifier: "local"|
      instance_double(Containers::Backends::LocalDocker, identifier: identifier)
    end
    allow(Containers::Backends::RemoteDocker).to receive(:new) do |host:, identifier:, proxy_external_url: nil, **_kwargs|
      instance_double(
        Containers::Backends::RemoteDocker,
        docker_url: host,
        identifier: identifier,
        proxy_external_url: proxy_external_url
      )
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

  it "supports Rails credentials references for remote TLS settings" do
    env["CONTAINER_BACKENDS_CONFIG"] = credential_backed_remote_config
    stub_tls_credentials

    registry = described_class.load(env: env)

    expect(registry.default_host).to eq("elguapo")
    expect(Containers::Backends::RemoteDocker).to have_received(:new).with(
      host: "tcp://100.113.201.1:2376",
      identifier: "elguapo",
      proxy_external_url: "https://paid.example.test",
      tls_config: {
        client_cert: "/secure/elguapo/cert.pem",
        client_key: "/secure/elguapo/key.pem",
        ssl_ca_file: "/secure/elguapo/ca.pem"
      }
    )
  end

  it "fails clearly when a remote host has an invalid configured proxy external URL" do
    env["CONTAINER_BACKENDS_CONFIG"] = <<~YAML
      default_host: elguapo
      hosts:
        elguapo:
          type: remote
          host: tcp://100.113.201.1:2376
          proxy_external_url: not a url
          tls:
            ca_file: /tmp/elguapo-ca.pem
            client_cert: /tmp/elguapo-cert.pem
            client_key: /tmp/elguapo-key.pem
    YAML

    expect {
      described_class.load(env: env)
    }.to raise_error(
      ArgumentError,
      /Docker host "elguapo" is invalid: Invalid proxy_external_url for Docker host "elguapo"/
    )
  end

  it "fails clearly when a remote host has incomplete TLS configuration" do
    env["CONTAINER_BACKENDS_CONFIG"] = <<~YAML
      default_host: local
      hosts:
        local:
          type: local
        elguapo:
          type: remote
          host: tcp://100.113.201.1:2376
          tls:
            client_cert: /tmp/elguapo-cert.pem
    YAML
    allow(Containers::Backends::RemoteDocker).to receive(:new)
      .and_raise(ArgumentError, "Remote Docker TLS config requires REMOTE_DOCKER_KEY, REMOTE_DOCKER_CA")

    expect {
      described_class.load(env: env)
    }.to raise_error(
      ArgumentError,
      /Docker host "elguapo" is invalid: Remote Docker TLS config requires REMOTE_DOCKER_KEY, REMOTE_DOCKER_CA/
    )
  end

  it "fails clearly when default_host is not defined" do
    env["CONTAINER_BACKENDS_CONFIG"] = <<~YAML
      default_host: elguapo
      hosts:
        local:
          type: local
    YAML

    expect {
      described_class.load(env: env)
    }.to raise_error(
      ArgumentError,
      /CONTAINER_BACKENDS_CONFIG default_host "elguapo" is not defined under hosts/
    )
  end

  def credential_backed_remote_config
    <<~YAML
      default_host: elguapo
      hosts:
        elguapo:
          type: remote
          host: tcp://100.113.201.1:2376
          proxy_external_url: https://paid.example.test
          tls:
            ca_file:
              credentials: [docker_hosts, elguapo, ca_file]
            client_cert:
              credential: docker_hosts.elguapo.client_cert
            client_key:
              credential: docker_hosts.elguapo.client_key
    YAML
  end

  def stub_tls_credentials
    allow(credentials).to receive(:dig).with(:docker_hosts, :elguapo, :ca_file).and_return("/secure/elguapo/ca.pem")
    allow(credentials).to receive(:dig).with(:docker_hosts, :elguapo, :client_cert).and_return("/secure/elguapo/cert.pem")
    allow(credentials).to receive(:dig).with(:docker_hosts, :elguapo, :client_key).and_return("/secure/elguapo/key.pem")
  end

  describe "single-backend mode declared capacity" do
    before do
      allow(Containers::Backends::LocalDocker).to receive(:new) do |identifier: "local"|
        instance_double(Containers::Backends::LocalDocker, identifier: identifier)
      end
      allow(Containers).to receive(:backend).and_return(
        instance_double(Containers::Backends::LocalDocker, identifier: "local")
      )
    end

    it "reads max_concurrent_runs from MAX_CONCURRENT_EXECUTIONS in single-backend mode" do
      registry = described_class.load(env: { "MAX_CONCURRENT_EXECUTIONS" => "20" })

      expect(registry.host_limit_for("local")).to eq(20)
    end

    it "defaults to nil (unlimited) when MAX_CONCURRENT_EXECUTIONS is unset" do
      registry = described_class.load(env: {})

      expect(registry.host_limit_for("local")).to be_nil
    end

    it "ignores invalid MAX_CONCURRENT_EXECUTIONS values" do
      registry = described_class.load(env: { "MAX_CONCURRENT_EXECUTIONS" => "abc" })

      expect(registry.host_limit_for("local")).to be_nil
    end
  end
end
