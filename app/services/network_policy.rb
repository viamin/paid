# frozen_string_literal: true

require "docker-api"
require "ipaddr"
require "net/http"
require "json"

# Manages Docker network isolation for agent containers.
#
# Ensures the restricted agent network exists and applies firewall rules
# to limit outbound traffic to only allowed destinations (secrets proxy, GitHub).
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

  NETWORK_NAME = "paid_agent"

  # Infrastructure network with outbound routing.
  # Used by subscription-auth containers that need to reach Anthropic directly.
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
    # Returns the network name that agent containers should use.
    # Subscription-auth containers use the infrastructure network (paid_internal)
    # for outbound HTTPS access; API-key containers use the restricted network.
    #
    # @return [String] Docker network name
    def agent_network
      subscription_auth? ? INFRA_NETWORK_NAME : NETWORK_NAME
    end

    # Returns true when Claude CLI config is available for
    # subscription-based authentication (e.g. from `claude login`).
    #
    # Mirrors the detection logic in Containers::Provision#subscription_auth?
    # so that service containers are always placed on the same network as the
    # agent container. Checks CLAUDE_CONFIG_DIR first, then auto-detects a
    # standard Claude config mount (for DooD/devcontainer setups).
    #
    # @return [Boolean]
    def subscription_auth?
      claude_config_dir.present?
    end

    # Ensures the agent Docker network exists. Creates it if missing.
    #
    # @return [Docker::Network] the agent network
    # @raise [Error] if network creation fails
    def ensure_network!
      Docker::Network.get(NETWORK_NAME)
    rescue Docker::Error::NotFoundError
      create_network
    end

    # Checks whether the agent network exists.
    #
    # @return [Boolean]
    def network_exists?
      Docker::Network.get(NETWORK_NAME)
      true
    rescue Docker::Error::NotFoundError
      false
    end

    # Applies iptables-based firewall rules inside a container to restrict
    # outbound traffic. Only allows: secrets proxy, GitHub, and DNS.
    #
    # Requires NET_RAW capability on the container.
    #
    # @param container [Docker::Container] running container to apply rules to
    # @param github_ips [Array<String>] GitHub CIDR ranges to allow
    # @param proxy_host [String] hostname or IPv4 address of the secrets proxy
    # @return [void]
    # @raise [Error] if applying rules fails
    # @param container [Docker::Container] running container to apply rules to
    # @param github_ips [Array<String>] GitHub CIDR ranges to allow
    # @param proxy_host [String] hostname or IPv4 address of the secrets proxy
    # @param service_destinations [Array<Hash>] service containers to allow,
    #   each with :ip and :port keys (e.g., { ip: "172.28.0.5", port: 5432 })
    def apply_firewall_rules(container, github_ips: nil, proxy_host: nil, service_destinations: [])
      github_ips ||= DEFAULT_GITHUB_IPS
      proxy_host ||= default_proxy_host

      validated_ips = github_ips.map { |cidr| validate_cidr!(cidr) }
      validated_host = validate_host!(proxy_host)

      script = build_firewall_script(
        github_ips: validated_ips,
        proxy_host: validated_host,
        service_destinations: service_destinations
      )

      _stdout, stderr, exit_code = container.exec([ "sh", "-c", script ])

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

    # Returns the Claude config directory path, checking the explicit
    # environment variable first, then auto-detecting standard locations.
    #
    # Mirrors Containers::Provision#subscription_auth? detection:
    # - ENV["CLAUDE_CONFIG_DIR"] (explicit override)
    # - $HOME/.claude (DooD/devcontainer mount from host)
    # - $HOME/.config/claude (standard Claude CLI config on Linux)
    def claude_config_dir
      return ENV["CLAUDE_CONFIG_DIR"] if ENV["CLAUDE_CONFIG_DIR"].present?

      home = ENV["HOME"].presence || (Dir.respond_to?(:home) ? Dir.home : nil)

      if home.present?
        # Check $HOME/.claude first — in DooD setups the host mounts ~/.claude
        # into the devcontainer, which Containers::Provision detects via Docker
        # mount introspection. We check the filesystem equivalent here.
        dot_claude = File.join(home, ".claude")
        return dot_claude if Dir.exist?(dot_claude)

        # Fall back to standard Claude CLI config location on Linux.
        config_claude = File.join(home, ".config", "claude")
        return config_claude if Dir.exist?(config_claude)
      end

      # Last-resort check matching Containers::Provision's Docker mount
      # detection of a /.claude destination. Without $HOME we cannot build
      # a path, but /.claude may exist as a direct mount point.
      "/.claude" if Dir.exist?("/.claude")
    end

    def create_network
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

      Docker::Network.create(NETWORK_NAME, config)
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

    def default_proxy_host
      # Default to the hostname used by agents to reach the secrets proxy.
      # This keeps firewall rules aligned with the container environment.
      "paid-proxy"
    end

    def build_firewall_script(github_ips:, proxy_host:, service_destinations: [])
      github_rules = github_ips.flat_map do |cidr|
        [
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 443 -j ACCEPT",
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 22 -j ACCEPT"
        ]
      end

      service_rules = service_destinations.map do |dest|
        "iptables -A OUTPUT -d #{validate_host!(dest[:ip])} -p tcp --dport #{dest[:port].to_i} -j ACCEPT"
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
        iptables -A OUTPUT -d #{proxy_host} -p tcp --dport #{SECRETS_PROXY_PORT} -j ACCEPT

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
