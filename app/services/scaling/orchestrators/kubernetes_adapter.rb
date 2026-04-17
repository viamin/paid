# frozen_string_literal: true

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
    # - +kubeconfig_path+ — Path to kubeconfig file. When nil, uses
    #   in-cluster config (the default for pods running inside K8s).
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

      attr_reader :namespace, :api_url

      # TODO(#727): Wire up kubeconfig-based auth — parse kubeconfig for server
      # URL and token when api_url/bearer_token are not explicitly provided.
      def initialize(namespace: "default", kubeconfig_path: nil, api_url: nil, bearer_token: nil, **)
        @namespace = namespace
        @kubeconfig_path = kubeconfig_path
        @api_url = api_url
        @bearer_token = bearer_token
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
        api_get("/api/v1/namespaces/#{namespace}")
        true
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
        connection.patch(path, body.to_json) do |req|
          req.headers["Authorization"] = "Bearer #{bearer_token}" if bearer_token
          req.headers["Content-Type"] = "application/strategic-merge-patch+json"
          req.headers["Accept"] = "application/json"
        end
      rescue Faraday::Error => e
        raise ApiError, e.message
      end

      def connection
        @connection ||= Faraday.new(url: resolve_api_url) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end

      def resolve_api_url
        return api_url if api_url.present?

        "https://kubernetes.default.svc"
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
