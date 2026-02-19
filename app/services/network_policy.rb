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

  SECRETS_PROXY_PORT = ENV.fetch("PAID_PROXY_PORT", "3000").to_i

  class << self
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
    def apply_firewall_rules(container, github_ips: nil, proxy_host: nil)
      github_ips ||= DEFAULT_GITHUB_IPS
      proxy_host ||= default_proxy_host

      validated_ips = github_ips.map { |cidr| validate_cidr!(cidr) }
      validated_host = validate_host!(proxy_host)

      script = build_firewall_script(github_ips: validated_ips, proxy_host: validated_host)

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

    def build_firewall_script(github_ips:, proxy_host:)
      github_rules = github_ips.flat_map do |cidr|
        [
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 443 -j ACCEPT",
          "iptables -A OUTPUT -d #{cidr} -p tcp --dport 22 -j ACCEPT"
        ]
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

        # Log and drop everything else
        iptables -A OUTPUT -j LOG --log-prefix "PAID_AGENT_BLOCK: " --log-level 4
        iptables -A OUTPUT -j DROP
      SCRIPT
    end
  end
end
