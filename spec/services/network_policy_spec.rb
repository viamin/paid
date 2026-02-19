# frozen_string_literal: true

require "rails_helper"

RSpec.describe NetworkPolicy do
  let(:mock_network) do
    instance_double(
      Docker::Network,
      info: {
        "IPAM" => {
          "Config" => [ { "Subnet" => "172.28.0.0/16", "Gateway" => "172.28.0.1" } ]
        }
      }
    )
  end

  let(:mock_container) do
    instance_double(Docker::Container, id: "abc123", exec: [ [], [], 0 ])
  end

  describe ".ensure_network!" do
    context "when network already exists" do
      before do
        allow(Docker::Network).to receive(:get)
          .with(described_class::NETWORK_NAME)
          .and_return(mock_network)
      end

      it "returns the existing network" do
        result = described_class.ensure_network!
        expect(result).to eq(mock_network)
      end

      it "does not create a new network" do
        expect(Docker::Network).not_to receive(:create)
        described_class.ensure_network!
      end
    end

    context "when network does not exist" do
      before do
        allow(Docker::Network).to receive(:get)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Network).to receive(:create).and_return(mock_network)
      end

      it "creates the network with correct configuration" do
        expect(Docker::Network).to receive(:create).with(
          described_class::NETWORK_NAME,
          hash_including(
            "Driver" => "bridge",
            "IPAM" => hash_including(
              "Config" => [ { "Subnet" => described_class::NETWORK_SUBNET } ]
            )
          )
        ).and_return(mock_network)

        described_class.ensure_network!
      end

      context "when in production" do
        before { allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production")) }

        it "creates an internal network with masquerade disabled" do
          expect(Docker::Network).to receive(:create).with(
            described_class::NETWORK_NAME,
            hash_including(
              "Internal" => true,
              "Options" => hash_including(
                "com.docker.network.bridge.enable_ip_masquerade" => "false"
              )
            )
          ).and_return(mock_network)

          described_class.ensure_network!
        end
      end

      context "when in development" do
        it "creates a non-internal network" do
          expect(Docker::Network).to receive(:create).with(
            described_class::NETWORK_NAME,
            hash_not_including("Internal" => true)
          ).and_return(mock_network)

          described_class.ensure_network!
        end
      end

      it "returns the newly created network" do
        result = described_class.ensure_network!
        expect(result).to eq(mock_network)
      end
    end

    context "when network creation fails" do
      before do
        allow(Docker::Network).to receive(:get)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
        allow(Docker::Network).to receive(:create)
          .and_raise(Docker::Error::ServerError.new("Docker error"))
      end

      it "raises NetworkPolicy::Error" do
        expect { described_class.ensure_network! }
          .to raise_error(described_class::Error, /Failed to create agent network/)
      end
    end
  end

  describe ".network_exists?" do
    context "when network exists" do
      before do
        allow(Docker::Network).to receive(:get)
          .with(described_class::NETWORK_NAME)
          .and_return(mock_network)
      end

      it "returns true" do
        expect(described_class.network_exists?).to be true
      end
    end

    context "when network does not exist" do
      before do
        allow(Docker::Network).to receive(:get)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "returns false" do
        expect(described_class.network_exists?).to be false
      end
    end
  end

  describe ".apply_firewall_rules" do
    context "when rules apply successfully" do
      before do
        allow(mock_container).to receive(:exec).and_return([ [], [], 0 ])
      end

      it "executes a shell script via exec" do
        expect(mock_container).to receive(:exec) do |cmd|
          expect(cmd.length).to eq(3)
          expect(cmd[0]).to eq("sh")
          expect(cmd[1]).to eq("-c")
          expect(cmd[2]).to be_a(String)
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container)
      end

      it "includes all required iptables rules in the script" do
        expect(mock_container).to receive(:exec) do |cmd|
          script = cmd[2]
          expect(script).to include("iptables -P OUTPUT DROP")
          expect(script).to include("iptables -A OUTPUT -o lo -j ACCEPT")
          expect(script).to include("ESTABLISHED,RELATED")
          expect(script).to include("--dport 53")
          expect(script).to include("--dport #{described_class::SECRETS_PROXY_PORT}")
          expect(script).to include("PAID_AGENT_BLOCK")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container)
      end

      it "includes GitHub IP rules" do
        expect(mock_container).to receive(:exec) do |cmd|
          script = cmd[2]
          described_class::DEFAULT_GITHUB_IPS.each do |cidr|
            expect(script).to include("-d #{cidr} -p tcp --dport 443")
            expect(script).to include("-d #{cidr} -p tcp --dport 22")
          end
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container)
      end

      it "accepts custom GitHub IPs" do
        custom_ips = [ "10.0.0.0/8" ]

        expect(mock_container).to receive(:exec) do |cmd|
          script = cmd[2]
          expect(script).to include("-d 10.0.0.0/8 -p tcp --dport 443")
          expect(script).not_to include("140.82.112.0/20")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, github_ips: custom_ips)
      end

      it "accepts custom proxy host" do
        expect(mock_container).to receive(:exec) do |cmd|
          script = cmd[2]
          expect(script).to include("-d 10.0.0.1 -p tcp --dport #{described_class::SECRETS_PROXY_PORT}")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, proxy_host: "10.0.0.1")
      end
    end

    context "when rules fail to apply" do
      before do
        allow(mock_container).to receive(:exec)
          .and_return([ [], [ "iptables: Permission denied" ], 1 ])
      end

      it "raises NetworkPolicy::Error" do
        expect { described_class.apply_firewall_rules(mock_container) }
          .to raise_error(described_class::Error, /Failed to apply firewall rules/)
      end
    end

    context "with invalid github_ips" do
      it "raises NetworkPolicy::Error for malformed CIDR" do
        expect { described_class.apply_firewall_rules(mock_container, github_ips: [ "not-a-cidr" ]) }
          .to raise_error(described_class::Error, /Invalid CIDR/)
      end

      it "raises NetworkPolicy::Error for shell injection in CIDR" do
        expect { described_class.apply_firewall_rules(mock_container, github_ips: [ "10.0.0.0/8; rm -rf /" ]) }
          .to raise_error(described_class::Error, /Invalid CIDR/)
      end
    end

    context "with invalid proxy_host" do
      it "raises NetworkPolicy::Error for shell metacharacters" do
        expect { described_class.apply_firewall_rules(mock_container, proxy_host: "host; rm -rf /") }
          .to raise_error(described_class::Error, /Invalid proxy host/)
      end

      it "raises NetworkPolicy::Error for backtick injection" do
        expect { described_class.apply_firewall_rules(mock_container, proxy_host: "`whoami`") }
          .to raise_error(described_class::Error, /Invalid proxy host/)
      end
    end
  end

  describe ".fetch_github_ips" do
    let(:github_meta_body) do
      {
        "hooks" => [ "192.30.252.0/22" ],
        "git" => [ "140.82.112.0/20" ],
        "api" => [ "140.82.112.0/20", "185.199.108.0/22" ],
        "web" => [ "140.82.112.0/20" ]
      }.to_json
    end

    context "when GitHub API responds successfully" do
      before do
        mock_response = instance_double(Net::HTTPSuccess, body: github_meta_body)
        allow(mock_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(Net::HTTP).to receive(:start).and_return(mock_response)
      end

      it "returns deduplicated IP ranges" do
        result = described_class.fetch_github_ips

        expect(result).to include("192.30.252.0/22")
        expect(result).to include("140.82.112.0/20")
        expect(result).to include("185.199.108.0/22")
        expect(result.length).to eq(result.uniq.length)
      end
    end

    context "when GitHub API fails" do
      before do
        allow(Net::HTTP).to receive(:start).and_raise(SocketError, "Connection refused")
      end

      it "returns default GitHub IPs" do
        result = described_class.fetch_github_ips
        expect(result).to eq(described_class::DEFAULT_GITHUB_IPS)
      end

      it "logs the failure" do
        expect(Rails.logger).to receive(:warn).with(
          hash_including(message: "network_policy.fetch_github_ips.failed")
        )

        described_class.fetch_github_ips
      end
    end
  end

  describe "constants" do
    it "defines the network name" do
      expect(described_class::NETWORK_NAME).to eq("paid_agent")
    end

    it "defines the network subnet" do
      expect(described_class::NETWORK_SUBNET).to eq("172.28.0.0/16")
    end

    it "defines the secrets proxy port" do
      expect(described_class::SECRETS_PROXY_PORT).to eq(3000)
    end

    it "defines default GitHub IP ranges" do
      expect(described_class::DEFAULT_GITHUB_IPS).to be_a(Array)
      expect(described_class::DEFAULT_GITHUB_IPS).not_to be_empty
      expect(described_class::DEFAULT_GITHUB_IPS).to all(match(%r{\d+\.\d+\.\d+\.\d+/\d+}))
    end
  end
end
