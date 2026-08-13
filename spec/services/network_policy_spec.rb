# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-018
RSpec.describe NetworkPolicy, :no_db do
  let(:backend) { Containers.backend }
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
        allow(backend).to receive(:get_network)
          .with(described_class::NETWORK_NAME)
          .and_return(mock_network)
      end

      it "returns the existing network" do
        result = described_class.ensure_network!
        expect(result).to eq(mock_network)
      end

      it "does not create a new network" do
        expect(backend).not_to receive(:create_network)
        described_class.ensure_network!
      end
    end

    context "when network does not exist" do
      before do
        allow(backend).to receive(:get_network)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
        allow(backend).to receive(:create_network).and_return(mock_network)
      end

      it "creates the network with correct configuration" do
        expect(backend).to receive(:create_network).with(
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
          expect(backend).to receive(:create_network).with(
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
          expect(backend).to receive(:create_network).with(
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
        allow(backend).to receive(:get_network)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
        allow(backend).to receive(:create_network)
          .and_raise(Docker::Error::ServerError.new("Docker error"))
      end

      it "raises NetworkPolicy::Error" do
        expect { described_class.ensure_network! }
          .to raise_error(described_class::Error, /Failed to create agent network/)
      end
    end

    context "when the infrastructure network is missing" do
      before do
        allow(backend).to receive(:get_network)
          .with(described_class::INFRA_NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "raises instead of creating the infrastructure network" do
        expect(backend).not_to receive(:create_network)

        expect { described_class.ensure_network!(network: described_class::INFRA_NETWORK_NAME) }
          .to raise_error(described_class::Error, /paid_internal does not exist/)
      end
    end
  end

  describe ".network_exists?" do
    context "when network exists" do
      before do
        allow(backend).to receive(:get_network)
          .with(described_class::NETWORK_NAME)
          .and_return(mock_network)
      end

      it "returns true" do
        expect(described_class.network_exists?).to be true
      end
    end

    context "when network does not exist" do
      before do
        allow(backend).to receive(:get_network)
          .with(described_class::NETWORK_NAME)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "returns false" do
        expect(described_class.network_exists?).to be false
      end
    end
  end

  describe ".apply_firewall_rules" do
    around do |example|
      original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
      original_host_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"]
      example.run
    ensure
      ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
      ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"] = original_host_proxy_external_url
    end

    context "when rules apply successfully" do
      before do
        allow(backend).to receive(:exec_in_container).and_return([ [], [], 0 ])
      end

      it "executes a shell script via exec" do
        expect(backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
          expect(cmd.length).to eq(3)
          expect(cmd[0]).to eq("sh")
          expect(cmd[1]).to eq("-c")
          expect(cmd[2]).to be_a(String)
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container)
      end

      it "includes all required iptables rules in the script" do
        expect(backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
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
        expect(backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
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

        expect(backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
          script = cmd[2]
          expect(script).to include("-d 10.0.0.0/8 -p tcp --dport 443")
          expect(script).not_to include("140.82.112.0/20")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, github_ips: custom_ips)
      end

      it "accepts custom proxy host" do
        expect(backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
          script = cmd[2]
          expect(script).to include("-d 10.0.0.1 -p tcp --dport #{described_class::SECRETS_PROXY_PORT}")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, proxy_host: "10.0.0.1")
      end

      it "uses PAID_PROXY_EXTERNAL_URL for remote backends" do
        remote_backend = instance_double(
          Containers::Backends::Base,
          identifier: "worker-1",
          remote?: true,
          exec_in_container: [ [], [], 0 ]
        )
        ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

        expect(remote_backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
          expect(cmd[2]).to include("-d proxy.example.test -p tcp --dport 3443")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, backend: remote_backend)
      end

      it "prefers PAID_PROXY_EXTERNAL_URL_<HOST> for remote backends" do
        remote_backend = instance_double(
          Containers::Backends::Base,
          identifier: "worker-1",
          remote?: true,
          exec_in_container: [ [], [], 0 ]
        )
        ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
        ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"] = "https://worker-1-proxy.example.test:3555"

        expect(remote_backend).to receive(:exec_in_container).with(mock_container, kind_of(Array)) do |_container, cmd|
          expect(cmd[2]).to include("-d worker-1-proxy.example.test -p tcp --dport 3555")
          [ [], [], 0 ]
        end

        described_class.apply_firewall_rules(mock_container, backend: remote_backend)
      end
    end

    context "when rules fail to apply" do
      before do
        allow(backend).to receive(:exec_in_container)
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

      it "raises NetworkPolicy::Error for invalid PAID_PROXY_EXTERNAL_URL" do
        remote_backend = instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true)
        ENV["PAID_PROXY_EXTERNAL_URL"] = "not a url"

        expect { described_class.apply_firewall_rules(mock_container, backend: remote_backend) }
          .to raise_error(described_class::Error, /Invalid PAID_PROXY_EXTERNAL_URL/)
      end

      it "raises NetworkPolicy::Error when the remote backend has no external proxy URL" do
        remote_backend = instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true)
        ENV.delete("PAID_PROXY_EXTERNAL_URL")
        ENV.delete("PAID_PROXY_EXTERNAL_URL_WORKER_1")

        expect { described_class.apply_firewall_rules(mock_container, backend: remote_backend) }
          .to raise_error(described_class::Error, /PAID_PROXY_EXTERNAL_URL.*is required/)
      end

      it "raises NetworkPolicy::Error for an invalid PAID_PROXY_EXTERNAL_URL port" do
        remote_backend = instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true)
        ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:99999"

        expect { described_class.apply_firewall_rules(mock_container, backend: remote_backend) }
          .to raise_error(described_class::Error, /PAID_PROXY_EXTERNAL_URL port must be between 1 and 65535/)
      end

      it "raises NetworkPolicy::Error for an unsupported PAID_PROXY_EXTERNAL_URL scheme" do
        remote_backend = instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true)
        ENV["PAID_PROXY_EXTERNAL_URL"] = "ssh://proxy.example.test:3443"

        expect { described_class.apply_firewall_rules(mock_container, backend: remote_backend) }
          .to raise_error(described_class::Error, /must use http or https/)
      end
    end

    context "with invalid service destinations" do
      it "raises NetworkPolicy::Error for shell metacharacters in the port" do
        expect {
          described_class.apply_firewall_rules(
            mock_container,
            service_destinations: [ { ip: "172.28.0.5", port: "5432; rm -rf /" } ]
          )
        }.to raise_error(described_class::Error, /Invalid service port/)
      end

      it "raises NetworkPolicy::Error for out-of-range service ports" do
        expect {
          described_class.apply_firewall_rules(
            mock_container,
            service_destinations: [ { ip: "172.28.0.5", port: 65_536 } ]
          )
        }.to raise_error(described_class::Error, /Invalid service port/)
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

  describe ".subscription_auth?" do
    around do |example|
      # Isolate env vars used by config dir detection
      original_env = ENV.to_h.slice(
        "CLAUDE_CONFIG_DIR", "CODEX_CONFIG_DIR", "CODEX_HOME", "GEMINI_CONFIG_DIR", "COPILOT_HOME", "COPILOT_CONFIG_DIR"
      )
      ENV.delete("CLAUDE_CONFIG_DIR")
      ENV.delete("CODEX_CONFIG_DIR")
      ENV.delete("CODEX_HOME")
      ENV.delete("GEMINI_CONFIG_DIR")
      ENV.delete("COPILOT_HOME")
      ENV.delete("COPILOT_CONFIG_DIR")
      example.run
    ensure
      original_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    context "when no provider credentials exist" do
      before do
        allow(Dir).to receive(:exist?).and_return(false)
        allow(File).to receive(:file?).and_return(false)
      end

      it "returns false" do
        expect(described_class.subscription_auth?).to be false
      end

      it "selects the restricted agent network" do
        expect(described_class.agent_network).to eq(described_class::NETWORK_NAME)
      end
    end

    context "when only Claude credentials exist" do
      before do
        allow(Dir).to receive(:exist?).and_return(false)
        allow(Dir).to receive(:exist?).with("/tmp/claude-test").and_return(true)
        ENV["CLAUDE_CONFIG_DIR"] = "/tmp/claude-test"
        allow(File).to receive(:file?).and_return(false)
        allow(File).to receive(:file?)
          .with("/tmp/claude-test/.credentials.json").and_return(true)
      end

      it "returns true" do
        expect(described_class.subscription_auth?).to be true
      end

      it "selects the infrastructure network" do
        expect(described_class.agent_network).to eq(described_class::INFRA_NETWORK_NAME)
      end
    end

    context "when only Codex credentials exist" do
      before do
        allow(Dir).to receive(:exist?).and_return(false)
        allow(Dir).to receive(:exist?).with("/tmp/codex-test").and_return(true)
        ENV["CODEX_CONFIG_DIR"] = "/tmp/codex-test"
        allow(File).to receive(:file?).and_return(false)
        allow(File).to receive(:file?)
          .with("/tmp/codex-test/auth.json").and_return(true)
      end

      it "returns true" do
        expect(described_class.subscription_auth?).to be true
      end

      it "selects the infrastructure network" do
        expect(described_class.agent_network).to eq(described_class::INFRA_NETWORK_NAME)
      end
    end

    context "when only Gemini credentials exist" do
      before do
        allow(Dir).to receive(:exist?).and_return(false)
        allow(Dir).to receive(:exist?).with("/tmp/gemini-test").and_return(true)
        ENV["GEMINI_CONFIG_DIR"] = "/tmp/gemini-test"
        allow(File).to receive(:file?).and_return(false)
        allow(File).to receive(:file?)
          .with("/tmp/gemini-test/oauth_creds.json").and_return(true)
      end

      it "returns true" do
        expect(described_class.subscription_auth?).to be true
      end

      it "selects the infrastructure network" do
        expect(described_class.agent_network).to eq(described_class::INFRA_NETWORK_NAME)
      end
    end

    context "when only Copilot credentials exist" do
      before do
        allow(Dir).to receive(:exist?).and_return(false)
        allow(Dir).to receive(:exist?).with("/tmp/copilot-test").and_return(true)
        ENV["COPILOT_HOME"] = "/tmp/copilot-test"
        allow(File).to receive(:file?).and_return(false)
        allow(File).to receive(:file?)
          .with("/tmp/copilot-test/config.json").and_return(true)
      end

      it "returns true" do
        expect(described_class.subscription_auth?).to be true
      end

      it "selects the infrastructure network" do
        expect(described_class.agent_network).to eq(described_class::INFRA_NETWORK_NAME)
      end
    end
  end

  describe ".contract" do
    it "returns the restricted proxy-mode contract by default" do
      contract = described_class.contract(subscription_auth: false)

      expect(contract.mode).to eq(:proxy)
      expect(contract.network).to eq(described_class::NETWORK_NAME)
      expect(contract).to be_restricted
      expect(contract).to be_firewall
    end

    it "returns the infrastructure contract for subscription auth" do
      contract = described_class.contract(subscription_auth: true)

      expect(contract.mode).to eq(:subscription_auth)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
      expect(contract).not_to be_firewall
    end

    it "returns the infrastructure contract for direct outbound providers" do
      contract = described_class.contract(subscription_auth: false, direct_outbound: true)

      expect(contract.mode).to eq(:direct_outbound)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
      expect(contract).not_to be_firewall
    end
  end

  describe ".contract_for_policy" do
    let(:policy_class) { ExecutionRunners::NetworkingPolicy }

    it "maps proxy_restricted to the restricted paid_agent network" do
      policy = policy_class.proxy_restricted

      contract = described_class.contract_for_policy(policy)

      expect(contract.mode).to eq(:proxy)
      expect(contract.network).to eq(described_class::NETWORK_NAME)
      expect(contract).to be_restricted
      expect(contract).to be_firewall
    end

    it "maps subscription_auth to the infrastructure paid_internal network" do
      contract = described_class.contract_for_policy(policy_class.subscription_auth)

      expect(contract.mode).to eq(:model_direct)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
      expect(contract).not_to be_firewall
    end

    it "maps direct_outbound to the infrastructure paid_internal network" do
      contract = described_class.contract_for_policy(policy_class.direct_outbound)

      expect(contract.mode).to eq(:model_direct)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
      expect(contract).not_to be_firewall
    end

    it "maps :model_direct to the infrastructure paid_internal network" do
      contract = described_class.contract_for_policy(policy_class.model_direct)

      expect(contract.mode).to eq(:model_direct)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
    end

    it "maps :explicit_internet to the infrastructure paid_internal network" do
      contract = described_class.contract_for_policy(policy_class.explicit_internet)

      expect(contract.mode).to eq(:explicit_internet)
      expect(contract.network).to eq(described_class::INFRA_NETWORK_NAME)
      expect(contract).not_to be_restricted
      expect(contract).not_to be_firewall
    end

    it "maps :no_outbound, :proxy_only, :git_plus_proxy, :approved_services to the restricted paid_agent network" do
      %i[no_outbound proxy_only git_plus_proxy approved_services].each do |mode|
        policy = policy_class.public_send(mode)
        contract = described_class.contract_for_policy(policy)

        expect(contract.network).to eq(described_class::NETWORK_NAME), "network for #{mode}"
        expect(contract).to be_restricted, "restricted for #{mode}"
        expect(contract).to be_firewall, "firewall for #{mode}"
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
