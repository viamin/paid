# frozen_string_literal: true

require "base64"
require "openssl"
require "pathname"
require "psych"

module Scaling
  module Orchestrators
    # Kubernetes adapter for the scaling orchestrator interface.
    #
    # Translates scaling actions into Kubernetes API calls targeting
    # Deployments and their associated Horizontal Pod Autoscalers (HPAs).
    # Supports both direct replica scaling and HPA min/max adjustment.
    #
    # == Configuration
    #
    # The adapter accepts the following configuration keys:
    #
    # - +namespace+ — Kubernetes namespace (default: +"default"+).
    # - +kubeconfig_path+ — Path to kubeconfig file. When nil, resolves
    #   via +ENV["KUBECONFIG"]+ or +~/.kube/config+.
    # - +api_url+ — Kubernetes API server URL. Overrides kubeconfig when set.
    # - +bearer_token+ — Authentication token. Overrides kubeconfig when set.
    #
    # == Usage
    #
    #   adapter = KubernetesAdapter.new(namespace: "production")
    #   status = adapter.current_status(service: "agent-worker")
    #   adapter.scale(service: "agent-worker", desired_replicas: 5)
    #
    class KubernetesAdapter
      include Scaling::Orchestrator

      class ApiError < OrchestratorError; end
      DEFAULT_KUBECONFIG_PATH = File.expand_path("~/.kube/config")

      attr_reader :namespace, :api_url

      def initialize(namespace: "default", kubeconfig_path: nil, api_url: nil, bearer_token: nil, **)
        @namespace = namespace
        @kubeconfig_path = expanded_kubeconfig_path(kubeconfig_path)

        config = resolved_config(api_url:, bearer_token:)
        @api_url = config.fetch(:api_url)
        @bearer_token = config[:bearer_token]
        @ssl_options = config[:ssl_options]
      end

      def current_status(service:)
        deployment = fetch_deployment(service)

        Data::ServiceStatus.new(
          service: service,
          current_replicas: deployment.dig(:status, :replicas) || 0,
          desired_replicas: deployment.dig(:spec, :replicas) || 0,
          available_replicas: deployment.dig(:status, :availableReplicas) || 0,
          cpu_usage: nil,
          memory_usage: nil,
          ready: deployment_ready?(deployment)
        )
      end

      def scale(service:, desired_replicas:)
        deployment = fetch_deployment(service)
        previous = deployment.dig(:spec, :replicas) || 0

        patch_deployment_replicas(service, desired_replicas)

        Data::ScaleResult.new(
          service: service,
          previous_replicas: previous,
          desired_replicas: desired_replicas,
          accepted: true,
          message: "Deployment #{service} scaled to #{desired_replicas} replicas"
        )
      end

      def set_resource_limits(service:, cpu_limit: nil, memory_limit: nil)
        limits = {}
        limits[:cpu] = cpu_limit if cpu_limit
        limits[:memory] = memory_limit if memory_limit

        patch_deployment_resources(service, limits)

        Data::ResourceUpdateResult.new(
          service: service,
          cpu_limit: cpu_limit,
          memory_limit: memory_limit,
          accepted: true,
          message: "Resource limits updated for #{service}"
        )
      end

      def healthy?
        response = api_get("/api/v1/namespaces/#{namespace}")
        response.success?
      rescue StandardError
        false
      end

      private

      attr_reader :bearer_token, :kubeconfig_path

      def fetch_deployment(service)
        response = api_get(deployment_path(service))
        parse_response(response)
      rescue ApiError => e
        raise ApiError, "Failed to fetch deployment #{service}: #{e.message}"
      end

      def patch_deployment_replicas(service, replicas)
        body = { spec: { replicas: replicas } }
        api_patch(deployment_path(service), body)
      end

      def patch_deployment_resources(service, limits)
        body = {
          spec: {
            template: {
              spec: {
                containers: [ { name: service, resources: { limits: limits } } ]
              }
            }
          }
        }
        api_patch(deployment_path(service), body)
      end

      def deployment_path(service)
        "/apis/apps/v1/namespaces/#{namespace}/deployments/#{service}"
      end

      def api_get(path)
        connection.get(path) do |req|
          req.headers["Authorization"] = "Bearer #{bearer_token}" if bearer_token
          req.headers["Accept"] = "application/json"
        end
      rescue Faraday::Error => e
        raise ApiError, e.message
      end

      def api_patch(path, body)
        response = connection.patch(path, body.to_json) do |req|
          req.headers["Authorization"] = "Bearer #{bearer_token}" if bearer_token
          req.headers["Content-Type"] = "application/strategic-merge-patch+json"
          req.headers["Accept"] = "application/json"
        end
        parse_response(response)
      rescue Faraday::Error => e
        raise ApiError, e.message
      end

      def connection
        @connection ||= Faraday.new(url: api_url, ssl: ssl_options) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end

      attr_reader :ssl_options

      def resolved_config(api_url:, bearer_token:)
        return { api_url:, bearer_token:, ssl_options: nil } if api_url.present? && bearer_token.present?

        kubeconfig = load_kubeconfig

        {
          api_url: api_url.presence || kubeconfig.fetch(:api_url),
          bearer_token: bearer_token.presence || kubeconfig[:bearer_token],
          ssl_options: kubeconfig[:ssl_options]
        }.tap do |config|
          next if config[:bearer_token].present? || config[:ssl_options].present?

          raise ApiError,
            "Kubeconfig #{kubeconfig_path} does not define a token or client certificate credentials"
        end
      end

      def load_kubeconfig
        raw_config = Psych.safe_load(File.read(kubeconfig_path), aliases: true)
        config = raw_config.is_a?(Hash) ? raw_config : {}
        context = fetch_named_entry(config["contexts"], config["current-context"], "current-context")
        cluster = fetch_named_entry(config["clusters"], context.dig("context", "cluster"), "cluster")
        user = fetch_named_entry(config["users"], context.dig("context", "user"), "user")

        {
          api_url: cluster.dig("cluster", "server").presence || missing_kubeconfig!("server"),
          bearer_token: resolve_bearer_token(user.fetch("user", {})),
          ssl_options: resolve_ssl_options(cluster.fetch("cluster", {}), user.fetch("user", {}))
        }
      rescue Errno::ENOENT
        raise ApiError, "Kubeconfig not found at #{kubeconfig_path}"
      rescue Psych::Exception => e
        raise ApiError, "Malformed kubeconfig at #{kubeconfig_path}: #{e.message}"
      rescue ArgumentError, OpenSSL::OpenSSLError => e
        raise ApiError, "Malformed kubeconfig credentials at #{kubeconfig_path}: #{e.message}"
      end

      def fetch_named_entry(entries, name, kind)
        missing_kubeconfig!(kind) if name.blank?

        Array(entries).find { |entry| entry["name"] == name } || missing_kubeconfig!("#{kind} #{name.inspect}")
      end

      def resolve_bearer_token(user)
        return user["token"] if user["token"].present?
        return File.read(expand_config_path(user["tokenFile"])).strip if user["tokenFile"].present?

        nil
      end

      def resolve_ssl_options(cluster, user)
        {}.tap do |options|
          store = cert_store(cluster)
          options[:cert_store] = store if store

          client_cert = pem_value(user, "client-certificate-data", "client-certificate")
          client_key = pem_value(user, "client-key-data", "client-key")
          next if client_cert.blank? && client_key.blank?

          if client_cert.blank? || client_key.blank?
            missing_kubeconfig!("client certificate or client key")
          end

          options[:client_cert] = OpenSSL::X509::Certificate.new(client_cert)
          options[:client_key] = OpenSSL::PKey.read(client_key)
        end.presence
      end

      def cert_store(cluster)
        store = OpenSSL::X509::Store.new
        if cluster["certificate-authority-data"].present?
          certificates_from(pem_data(cluster["certificate-authority-data"])).each { |cert| store.add_cert(cert) }
        elsif cluster["certificate-authority"].present?
          store.add_file(expand_config_path(cluster["certificate-authority"]))
        else
          return nil
        end

        store
      end

      def certificates_from(pem)
        certificates = pem.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m).map do |certificate|
          OpenSSL::X509::Certificate.new(certificate)
        end

        raise ArgumentError, "certificate-authority-data does not contain a PEM certificate" if certificates.empty?

        certificates
      end

      def pem_value(source, data_key, path_key)
        return pem_data(source[data_key]) if source[data_key].present?
        return File.read(expand_config_path(source[path_key])) if source[path_key].present?

        nil
      end

      def pem_data(value)
        Base64.strict_decode64(value)
      end

      def expanded_kubeconfig_path(path)
        candidate = path.presence || ENV["KUBECONFIG"].to_s.split(File::PATH_SEPARATOR).find(&:present?) || DEFAULT_KUBECONFIG_PATH
        File.expand_path(candidate)
      end

      def expand_config_path(path)
        expanded = Pathname.new(path).expand_path(Pathname.new(kubeconfig_path).dirname)
        expanded.to_s
      end

      def missing_kubeconfig!(key)
        raise ApiError, "Malformed kubeconfig at #{kubeconfig_path}: missing #{key}"
      end

      def parse_response(response)
        raise ApiError, "HTTP #{response.status}: #{response.body}" unless response.success?

        body = response.body
        body.is_a?(Hash) ? body.deep_symbolize_keys : body
      end

      def deployment_ready?(deployment)
        desired = deployment.dig(:spec, :replicas) || 0
        available = deployment.dig(:status, :availableReplicas) || 0
        desired > 0 && available >= desired
      end
    end
  end
end
