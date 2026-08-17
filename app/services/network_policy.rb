# frozen_string_literal: true

require "docker-api"
require "ipaddr"
require "json"
require "net/http"
require "uri"

# Manages Docker network selection and isolation for agent containers.
#
# Ensures the selected Docker network exists and applies firewall rules for
# proxy-mode runs on the restricted agent network.
#
# @example Ensure network is ready before provisioning
#   NetworkPolicy.ensure_network!
#
# @example Apply firewall rules inside a running container
#   NetworkPolicy.apply_firewall_rules(container)
#
# @example Fetch current GitHub IP ranges
#   ips = NetworkPolicy.fetch_github_ips
#
class NetworkPolicy
  # Raised when network operations fail
  class Error < StandardError; end

  # +mode+ values: :proxy (restricted runs), or the unrestricted
  # ExecutionRunners::NetworkingPolicy#mode (:model_direct,
  # :explicit_internet, :subscription_auth, :direct_outbound). Set by
  # {NetworkPolicy.contract_for_policy} during the runner-contract
  # translation (RDR-054, RDR-062).
  NetworkContract = Struct.new(:mode, :network, :restricted, :firewall, keyword_init: true) do
    def restricted?
      restricted
    end

    def firewall?
      firewall
    end
  end

  NETWORK_NAME = "paid_agent"

  # Infrastructure network with outbound routing.
  # Used by subscription-auth and direct-outbound containers that need to
  # reach provider APIs directly.
  INFRA_NETWORK_NAME = "paid_internal"

  NETWORK_SUBNET = "172.28.0.0/16"

  GITHUB_META_URL = "https://api.github.com/meta"

  # Static fallback GitHub IP ranges (from https://api.github.com/meta)
  DEFAULT_GITHUB_IPS = %w[
    140.82.112.0/20
    143.55.64.0/20
    185.199.108.0/22
    192.30.252.0/22
    20.201.28.0/24
  ].freeze

  SECRETS_PROXY_PORT = Rails.application.config.x.paid_proxy_port

  class << self
    # Returns the intended network contract for an agent container.
    #
    # Proxy mode uses the restricted paid_agent network plus in-container
    # firewall rules. Subscription-auth and direct-outbound runs use
    # paid_internal because provider CLIs must reach upstream provider APIs.
    #
    # @param subscription_auth [Boolean] whether host-backed provider auth is present
    # @param direct_outbound [Boolean] whether this run uses a provider that bypasses Paid's proxy
    # @return [NetworkContract]
    def contract(subscription_auth: subscription_auth?, direct_outbound: false)
      if subscription_auth
        unrestricted_contract(:subscription_auth)
      elsif direct_outbound
        unrestricted_contract(:direct_outbound)
      else
        restricted_contract
      end
    end

    # Translates a provider-neutral +ExecutionRunners::NetworkingPolicy+ into
    # the Docker-specific +NetworkContract+. The mapping is the only place
    # that knows which Docker network name corresponds to which runner-level
    # mode, keeping +paid_agent+ / +paid_internal+ out of the policy and the
    # runner (RDR-054, RDR-062).
    #
    # All four restricted intents (RDR-062: +:no_outbound+, +:proxy_only+,
    # +:git_plus_proxy+, +:approved_services+) share the +paid_agent+ Docker
    # network; the runner translates the intent to a firewall allowlist that
    # is narrower than the legacy approved-services default. The two
    # unrestricted intents (+:model_direct+, +:explicit_internet+) share
    # +paid_internal+ with no firewall.
    #
    # @param policy [ExecutionRunners::NetworkingPolicy]
    # @return [NetworkContract]
    # @spec CONTAINER-RUNTIME-019
    def contract_for_policy(policy)
      if policy.restricted?
        NetworkContract.new(
          mode: :proxy,
          network: NETWORK_NAME,
          restricted: true,
          firewall: policy.firewall?
        )
      else
        NetworkContract.new(
          mode: policy.canonical_mode,
          network: INFRA_NETWORK_NAME,
          restricted: false,
          firewall: false
        )
      end
    end

    # Returns the network name that agent containers should use.
    #
    # @param direct_outbound [Boolean] whether this run uses a provider that bypasses Paid's proxy
    # @return [String] Docker network name
    def agent_network(direct_outbound: false)
      contract(direct_outbound: direct_outbound).network
    end

    # Returns true when any provider CLI config is available for
    # subscription-based authentication (e.g. from `claude login`,
    # `gemini auth login`, Codex `auth.json`, or Copilot `config.json`).
    #
    # Mirrors the detection logic in Containers::Provision#subscription_auth?
    # so that service containers are always placed on the same network as the
    # agent container.
    #
    # @return [Boolean]
    def subscription_auth?
      claude_subscription_auth? || codex_subscription_auth? || gemini_subscription_auth? || copilot_subscription_auth?
    end

    # Ensures the agent Docker network exists. Creates it if missing.
    #
    # @return [Docker::Network] the agent network
    # @raise [Error] if network creation fails
    def ensure_network!(network: NETWORK_NAME, backend: Containers.backend)
      backend.get_network(network)
    rescue Docker::Error::NotFoundError
      raise Error, "Docker network #{network} does not exist" unless network == NETWORK_NAME

      create_network(backend: backend)
    end

    # Checks whether the agent network exists.
    #
    # @return [Boolean]
    def network_exists?(backend: Containers.backend)
      backend.get_network(NETWORK_NAME)
      true
    rescue Docker::Error::NotFoundError
      false
    end

    # Applies iptables-based firewall rules inside a container to restrict
    # outbound traffic. The firewall script always allows loopback, DNS, and
    # established/related responses. The secrets-proxy allow and GitHub CIDR
    # allow are independent — pass +proxy_host:+ or +github_ips:+ explicitly
    # when the policy intent allows them (RDR-062: :no_outbound omits both,
    # :proxy_only omits GitHub, :approved_services includes both plus
    # service container IPs).
    #
    # When +github_ips+ is +nil+ the caller's intent is "default GitHub
    # allowlist" (the legacy +DEFAULT_GITHUB_IPS+); pass +[]+ to omit
    # GitHub entirely (RDR-062 :no_outbound or :proxy_only). Pass
    # +proxy_host: false+ to omit the proxy allow rule entirely (RDR-062
    # :no_outbound).
    #
    # Requires NET_RAW capability on the container.
    #
    # @param container [Docker::Container] running container to apply rules to
    # @param github_ips [Array<String>, nil] GitHub CIDR ranges to allow; +nil+
    #   uses the legacy +DEFAULT_GITHUB_IPS+ default, +[]+ omits GitHub
    #   entirely.
    # @param proxy_host [String, false, nil] hostname or IPv4 address of the
    #   secrets proxy; +false+ omits the proxy allow rule entirely
    #   (RDR-062 :no_outbound), +nil+ uses the default proxy destination.
    # @param service_destinations [Array<Hash>] service containers to allow,
    #   each with :ip and :port keys (e.g., { ip: "172.28.0.5", port: 5432 })
    # @return [void]
    # @raise [Error] if applying rules fails
    # @spec CONTAINER-RUNTIME-019
    def apply_firewall_rules(container, github_ips: nil, proxy_host: nil, service_destinations: [], backend: Containers.backend)
      github_ips = github_ips.nil? ? DEFAULT_GITHUB_IPS : github_ips
      proxy_destination = if proxy_host == false
        nil
      elsif proxy_host.present?
        { host: proxy_host, port: SECRETS_PROXY_PORT }
      else
        default_proxy_destination(backend: backend)
      end

      validated_ips = github_ips.map { |cidr| validate_cidr!(cidr) }
      validated_host = proxy_destination ? validate_host!(proxy_destination.fetch(:host)) : nil
      validated_port = proxy_destination ? validate_port!(proxy_destination.fetch(:port), label: "proxy port") : nil

      script = build_firewall_script(
        github_ips: validated_ips,
        proxy_host: validated_host,
        proxy_port: validated_port,
        service_destinations: service_destinations
      )

      _stdout, stderr, exit_code = backend.exec_in_container(container, [ "sh", "-c", script ])

      return if exit_code == 0

      raise Error, "Failed to apply firewall rules (exit #{exit_code}): #{stderr&.join}"
    end

    # Fetches current GitHub IP ranges from the GitHub API.
    # Falls back to static defaults on failure.
    #
    # @return [Array<String>] CIDR ranges
    def fetch_github_ips
      uri = URI(GITHUB_META_URL)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
        http.get(uri.request_uri)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "HTTP #{response.code}: #{response.message}"
      end

      data = JSON.parse(response.body)
      %w[hooks git api web].flat_map { |key| data[key] || [] }.uniq
    rescue StandardError => e
      Rails.logger.warn(
        message: "network_policy.fetch_github_ips.failed",
        error: e.message
      )
      DEFAULT_GITHUB_IPS
    end

    private

    def restricted_contract
      NetworkContract.new(
        mode: :proxy,
        network: NETWORK_NAME,
        restricted: true,
        firewall: true
      )
    end

    def unrestricted_contract(mode)
      NetworkContract.new(
        mode: mode,
        network: INFRA_NETWORK_NAME,
        restricted: false,
        firewall: false
      )
    end

    # Per-provider subscription auth checks mirror
    # Containers::Provision#claude_subscription_auth? etc.
    # Each looks for the specific credential file that proves a real login.

    def claude_subscription_auth?
      dir = claude_config_dir
      dir.present? && File.file?(File.join(dir, ".credentials.json"))
    end

    def codex_subscription_auth?
      dir = codex_config_dir
      dir.present? && File.file?(File.join(dir, "auth.json"))
    end

    def gemini_subscription_auth?
      dir = gemini_config_dir
      dir.present? && File.file?(File.join(dir, "oauth_creds.json"))
    end

    def copilot_subscription_auth?
      dir = copilot_config_dir
      dir.present? && File.file?(File.join(dir, "config.json"))
    end

    # Returns the Claude config directory path, checking the explicit
    # environment variable first, then auto-detecting standard locations.
    def claude_config_dir
      if ENV["CLAUDE_CONFIG_DIR"].present?
        return ENV["CLAUDE_CONFIG_DIR"] if credential_present?(ENV["CLAUDE_CONFIG_DIR"], ".credentials.json")
      end

      home = home_dir
      if home.present?
        dot_claude = File.join(home, ".claude")
        return dot_claude if credential_present?(dot_claude, ".credentials.json")

        config_claude = File.join(home, ".config", "claude")
        return config_claude if credential_present?(config_claude, ".credentials.json")
      end

      "/.claude" if credential_present?("/.claude", ".credentials.json")
    end

    # Returns the Codex config directory path.
    def codex_config_dir
      [ ENV["CODEX_CONFIG_DIR"], ENV["CODEX_HOME"] ].each do |env_path|
        return env_path if env_path.present? && credential_present?(env_path, "auth.json")
      end

      home = home_dir
      if home.present?
        dot_codex = File.join(home, ".codex")
        return dot_codex if credential_present?(dot_codex, "auth.json")
      end

      "/.codex" if credential_present?("/.codex", "auth.json")
    end

    # Returns the Gemini config directory path.
    def gemini_config_dir
      if ENV["GEMINI_CONFIG_DIR"].present?
        return ENV["GEMINI_CONFIG_DIR"] if credential_present?(ENV["GEMINI_CONFIG_DIR"], "oauth_creds.json")
      end

      home = home_dir
      if home.present?
        dot_gemini = File.join(home, ".gemini")
        return dot_gemini if credential_present?(dot_gemini, "oauth_creds.json")
      end

      "/.gemini" if credential_present?("/.gemini", "oauth_creds.json")
    end

    # Returns the GitHub Copilot config directory path.
    def copilot_config_dir
      [ ENV["COPILOT_HOME"], ENV["COPILOT_CONFIG_DIR"] ].each do |env_path|
        return env_path if env_path.present? && credential_present?(env_path, "config.json")
      end

      home = home_dir
      if home.present?
        dot_copilot = File.join(home, ".copilot")
        return dot_copilot if credential_present?(dot_copilot, "config.json")
      end

      "/.copilot" if credential_present?("/.copilot", "config.json")
    end

    # Returns true when the directory exists and contains the given credential file.
    def credential_present?(dir, filename)
      Dir.exist?(dir) && File.file?(File.join(dir, filename))
    end

    def home_dir
      ENV["HOME"].presence || (Dir.respond_to?(:home) ? Dir.home : nil)
    end

    def create_network(backend:)
      Rails.logger.info(
        message: "network_policy.create_network",
        network: NETWORK_NAME,
        subnet: NETWORK_SUBNET
      )

      config = {
        "Driver" => "bridge",
        "IPAM" => {
          "Config" => [ { "Subnet" => NETWORK_SUBNET } ]
        }
      }

      if Rails.env.production?
        config["Internal"] = true
        config["Options"] = {
          "com.docker.network.bridge.enable_ip_masquerade" => "false"
        }
      end

      backend.create_network(NETWORK_NAME, config)
    rescue Docker::Error::DockerError => e
      raise Error, "Failed to create agent network: #{e.message}"
    end

    # Validates a CIDR notation string. Returns the validated string.
    def validate_cidr!(cidr)
      IPAddr.new(cidr)
      cidr
    rescue IPAddr::InvalidAddressError
      raise Error, "Invalid CIDR: #{cidr.inspect}"
    end

    # Validates a hostname or IPv4 address. Rejects shell metacharacters.
    def validate_host!(host)
      unless host.match?(/\A[a-zA-Z0-9.\-]+\z/)
        raise Error, "Invalid proxy host: #{host.inspect}"
      end
      host
    end

    def validate_port!(port, label: "port")
      port = Integer(port)
      raise Error, "Invalid #{label}: #{port}" unless port.between?(1, 65_535)

      port
    rescue ArgumentError, TypeError
      raise Error, "Invalid #{label}: #{port.inspect}"
    end

    def default_proxy_destination(backend: Containers.backend)
      if backend.remote?
        return external_proxy_destination(Containers::ProxyUrl.resolve(backend:, restricted: true))
      end

      { host: "paid-proxy", port: SECRETS_PROXY_PORT }
    rescue ArgumentError => e
      raise Error, e.message
    end

    def external_proxy_destination(url)
      uri = URI.parse(Containers::ProxyUrl.validate_external_url!(url))
      host = uri.host.presence or raise Error, "Invalid PAID_PROXY_EXTERNAL_URL: missing host"
      { host: host, port: uri.port }
    rescue ArgumentError => e
      raise Error, e.message
    rescue URI::InvalidURIError => e
      raise Error, "Invalid PAID_PROXY_EXTERNAL_URL: #{e.message}"
    end

    # @spec CONTAINER-RUNTIME-019
    def build_firewall_script(github_ips:, proxy_host:, proxy_port:, service_destinations: [])
      github_rules = github_ips.flat_map do |cidr|
        [
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 443 -j ACCEPT",
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 22 -j ACCEPT"
        ]
      end

      service_rules = service_destinations.map do |dest|
        service_port = validate_port!(dest[:port], label: "service port")
        "iptables -A OUTPUT -d #{validate_host!(dest[:ip])} -p tcp --dport #{service_port} -j ACCEPT"
      end

      proxy_rule = if proxy_host && proxy_port
        "iptables -A OUTPUT -d #{proxy_host} -p tcp --dport #{proxy_port} -j ACCEPT"
      else
        "# Secrets proxy omitted by RDR-062 :no_outbound intent"
      end

      <<~SCRIPT
        # Default deny all outbound
        iptables -P OUTPUT DROP

        # Allow loopback
        iptables -A OUTPUT -o lo -j ACCEPT

        # Allow established connections (for responses)
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # Allow DNS (for hostname resolution)
        iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

        # Allow secrets proxy
        #{proxy_rule}

        # Allow GitHub
        #{github_rules.join("\n")}

        #{service_rules.any? ? "# Allow service containers\n#{service_rules.join("\n")}" : ""}

        # Log and drop everything else
        iptables -A OUTPUT -j LOG --log-prefix "PAID_AGENT_BLOCK: " --log-level 4
        iptables -A OUTPUT -j DROP
      SCRIPT
    end
  end
end
