# frozen_string_literal: true

require "docker-api"
require "set"

module Containers
  module Backends
    class Swarm < Base
      DEFAULT_NODE_PORT = 2376
      DEFAULT_NODE_SCHEME = "https"
      NODE_HOSTNAME_CACHE_TTL = 30
      NODE_ADDRESS_LABEL = "paid.docker_host"

      VolumeHandle = Struct.new(:backend, :id, :host, keyword_init: true) do
        def remove(**options)
          backend.delete_volume(self, **options)
        end
      end

      class ServiceHandle
        attr_reader :backend, :id, :info, :task

        def initialize(backend:, service:, task: nil)
          @backend = backend
          @id = service.fetch("ID")
          @service = service
          @task = task
          @info = {}
          rebuild_info!
        end

        def exec(command, options = {}, &block)
          backend.exec_in_container(self, command, **options, &block)
        end

        def refresh!
          @service = backend.inspect_service(id)
          @task = backend.primary_task_for(id)
          rebuild_info!
          self
        end

        def service_id
          id
        end

        private

        def rebuild_info!
          @info = backend.service_info(@service, @task)
        end
      end

      def self.connection_options_from_env(env = ENV)
        cert_path = env["DOCKER_CERT_PATH"].presence || env["SWARM_CERT_PATH"].presence
        options = {}

        if cert_path
          options[:client_cert] = File.join(cert_path, "cert.pem")
          options[:client_key] = File.join(cert_path, "key.pem")
          options[:ssl_ca_file] = File.join(cert_path, "ca.pem")
          options[:scheme] = "https"
        end

        options[:ssl_verify_peer] = false if env["DOCKER_SSL_VERIFY"] == "false"
        options
      end

      def initialize(manager_host:, connection_options: {}, placement_constraints: nil, placement_preferences: nil,
        node_port: DEFAULT_NODE_PORT, node_scheme: DEFAULT_NODE_SCHEME)
        @manager_connection = Docker::Connection.new(manager_host, connection_options)
        @connection_options = connection_options
        @placement_constraints = list_value(placement_constraints)
        @placement_preferences = list_value(placement_preferences)
        @node_port = node_port
        @node_scheme = node_scheme
      end

      def identifier
        "swarm"
      end

      def supports_host_paths?
        false
      end

      def owns_host?(host)
        cached_node_hostnames.include?(host.to_s)
      end

      def ping
        manager_connection.ping
      end

      def container_host_for(container)
        node_hostname(node_for(container)) || identifier
      end

      def get_container(id)
        ServiceHandle.new(backend: self, service: inspect_service(id), task: primary_task_for(id))
      end

      def create_container(config)
        response = parse_json(
          manager_connection.post("/services/create", {}, body: MultiJson.dump(service_spec(config)))
        )
        get_container(response.fetch("ID"))
      end

      def start_container(container)
        container.refresh!
      end

      def stop_container(container, **options)
        concrete_container(container).stop(**options)
      end

      def delete_container(container, **_options)
        manager_connection.delete("/services/#{service_id(container)}")
      end

      def exec_in_container(container, command, **options, &block)
        concrete_container(container).exec(command, options, &block)
      end

      def container_stats(container, **options)
        concrete_container(container).stats(**options)
      end

      def container_logs(container, **options)
        concrete_container(container).streaming_logs(**options)
      end

      def list_containers(**options)
        query = options[:filters].present? ? { filters: options[:filters] } : {}
        parse_json(manager_connection.get("/services", query)).map do |service|
          ServiceHandle.new(backend: self, service: service, task: primary_task_for(service.fetch("ID")))
        end
      end

      def get_network(name)
        Docker::Network.get(name, {}, manager_connection)
      end

      def create_network(name, config)
        Docker::Network.create(name, swarm_network_config(config), manager_connection)
      end

      def pull_image(config)
        healthy_nodes.each do |node|
          Docker::Image.create(config, nil, node_connection(node))
        end
      end

      def list_volumes
        healthy_nodes.flat_map do |node|
          Docker::Volume.all({}, node_connection(node)).map do |volume|
            VolumeHandle.new(backend: self, id: volume.id, host: node_hostname(node))
          end
        end
      end

      def create_volume(name, _options = {}, host: nil)
        VolumeHandle.new(backend: self, id: name, host: host)
      end

      def get_volume(name, host: nil)
        return VolumeHandle.new(backend: self, id: name, host: host) if host.present?

        node = healthy_nodes.find do |candidate|
          Docker::Volume.get(name, node_connection(candidate))
          true
        rescue Docker::Error::NotFoundError
          false
        end
        raise Docker::Error::NotFoundError, "Volume #{name} not found" unless node

        VolumeHandle.new(backend: self, id: name, host: node_hostname(node))
      end

      def delete_volume(volume, **options)
        node = node_by_hostname(volume.host) || raise(Docker::Error::NotFoundError, "Swarm node #{volume.host.inspect} not found")
        Docker::Volume.get(volume.id, node_connection(node)).remove(options, node_connection(node))
      end

      def inspect_service(id)
        parse_json(manager_connection.get("/services/#{id}"))
      end

      def primary_task_for(service_id)
        tasks_for(service_id).max_by { |task| task.dig("Version", "Index").to_i }
      end

      def service_info(service, task)
        labels = service.dig("Spec", "TaskTemplate", "ContainerSpec", "Labels") || service.dig("Spec", "Labels") || {}
        node = node_for(task)
        concrete = concrete_container_info(task, node: node)
        state = service_state(task, concrete)

        info = concrete || {}
        info["Config"] = (info["Config"] || {}).merge("Labels" => labels)
        info["State"] = state
        info["Name"] ||= service["Spec"]["Name"]
        info["ServiceID"] = service["ID"]
        info["Node"] = node
        info
      end

      protected

      attr_reader :manager_connection

      private

      attr_reader :connection_options, :node_port, :node_scheme

      def service_spec(config)
        host_config = config.fetch("HostConfig", {})
        labels = config["Labels"] || {}

        {
          "Name" => config["name"],
          "Labels" => labels,
          "TaskTemplate" => {
            "ContainerSpec" => compact_hash(
              "Image" => config["Image"],
              "Labels" => labels,
              "Command" => config["Cmd"],
              "Env" => config["Env"],
              "Dir" => config["WorkingDir"],
              "User" => config["User"],
              "TTY" => config["Tty"],
              "OpenStdin" => config["OpenStdin"],
              "ReadOnly" => config["ReadonlyRootfs"],
              "Mounts" => build_mounts(host_config),
              "CapabilityAdd" => config["CapAdd"],
              "CapabilityDrop" => config["CapDrop"]
            ),
            "RestartPolicy" => { "Condition" => "none" },
            "Resources" => resource_limits(host_config),
            "Placement" => placement_spec
          },
          "Mode" => { "Replicated" => { "Replicas" => 1 } },
          "Networks" => [ { "Target" => host_config["NetworkMode"] } ]
        }
      end

      def placement_spec
        compact_hash(
          "Constraints" => @placement_constraints.presence,
          "Preferences" => @placement_preferences.map { |spread| { "Spread" => { "SpreadDescriptor" => spread } } }.presence
        )
      end

      def resource_limits(host_config)
        limits = compact_hash(
          "MemoryBytes" => host_config["Memory"],
          "NanoCPUs" => nano_cpus(host_config["CpuQuota"], host_config["CpuPeriod"])
        )

        compact_hash("Limits" => limits.presence)
      end

      def nano_cpus(cpu_quota, cpu_period)
        return nil unless cpu_quota.present? && cpu_period.present? && cpu_period.to_i.positive?

        ((cpu_quota.to_f / cpu_period.to_f) * 1_000_000_000).to_i
      end

      def build_mounts(host_config)
        binds = Array(host_config["Binds"])
        tmpfs = host_config["Tmpfs"] || {}

        mounts = binds.map { |bind| bind_mount(bind) }
        mounts.concat(tmpfs.map { |target, options| tmpfs_mount(target, options) })
        mounts
      end

      def bind_mount(bind)
        source, target, mode = bind.split(":", 3)
        type = source.start_with?("/") ? "bind" : "volume"

        compact_hash(
          "Type" => type,
          "Source" => source,
          "Target" => target,
          "ReadOnly" => mode.to_s.include?("ro")
        )
      end

      def tmpfs_mount(target, options)
        compact_hash(
          "Type" => "tmpfs",
          "Target" => target,
          "TmpfsOptions" => tmpfs_options(options)
        )
      end

      def tmpfs_options(options)
        parsed = list_value(options, separator: ",")
        mode = parsed.find { |part| part.start_with?("mode=") }&.delete_prefix("mode=")
        size = parsed.find { |part| part.start_with?("size=") }&.delete_prefix("size=")

        compact_hash(
          "Mode" => mode&.to_i(8),
          "SizeBytes" => size && parse_size(size)
        )
      end

      def parse_size(value)
        size = value.to_s
        return size.to_i if size.match?(/\A\d+\z/)

        amount = size[0...-1]
        multiplier = case size[-1]&.downcase
        when "k" then 1024
        when "m" then 1024 * 1024
        when "g" then 1024 * 1024 * 1024
        else 1
        end

        (amount.to_i * multiplier)
      end

      def concrete_container(container)
        task = task_for(container)
        raise Docker::Error::NotFoundError, "Swarm service has no active task" unless task

        node = node_for(task)
        raise Docker::Error::NotFoundError, "Swarm task node is unavailable" unless node

        container_id = task.dig("Status", "ContainerStatus", "ContainerID")
        raise Docker::Error::NotFoundError, "Swarm task has no runnable container" if container_id.blank?

        Docker::Container.get(container_id, {}, node_connection(node))
      end

      def concrete_container_info(task, node:)
        return nil unless task

        container_id = task.dig("Status", "ContainerStatus", "ContainerID")
        return nil if container_id.blank? || node.blank?

        Docker::Container.get(container_id, {}, node_connection(node)).json
      rescue Docker::Error::DockerError
        nil
      end

      def service_state(task, concrete_info)
        task_state = task&.dig("Status", "State")
        exit_code = concrete_info&.dig("State", "ExitCode") || task&.dig("Status", "ContainerStatus", "ExitCode")

        {
          "Running" => task_state == "running",
          "ExitCode" => exit_code,
          "Status" => task_state,
          "Error" => task&.dig("Status", "Err")
        }.compact
      end

      def task_for(container)
        return container.task if container.respond_to?(:task)

        primary_task_for(service_id(container))
      end

      def node_for(container_or_task)
        node_id = if container_or_task.is_a?(Hash)
          container_or_task["NodeID"]
        elsif container_or_task.respond_to?(:task)
          container_or_task.task&.dig("NodeID")
        end
        return nil if node_id.blank?

        inspect_node(node_id)
      end

      def service_id(container)
        return container.service_id if container.respond_to?(:service_id)

        container.id
      end

      def healthy_nodes
        parse_json(manager_connection.get("/nodes")).select do |node|
          node.dig("Spec", "Availability") == "active" &&
            node.dig("Status", "State") == "ready"
        end
      end

      def cached_node_hostnames
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @node_hostnames_expires_at.nil? || now >= @node_hostnames_expires_at
          @cached_node_hostnames = healthy_nodes.map { |node| node_hostname(node) }.compact.to_set
          @node_hostnames_expires_at = now + NODE_HOSTNAME_CACHE_TTL
        end

        @cached_node_hostnames
      end

      def inspect_node(id)
        parse_json(manager_connection.get("/nodes/#{id}"))
      end

      def node_by_hostname(hostname)
        healthy_nodes.find { |node| node_hostname(node) == hostname.to_s }
      end

      def node_hostname(node)
        node&.dig("Description", "Hostname")
      end

      def node_connection(node)
        Docker::Connection.new(node_url(node), connection_options)
      end

      def node_url(node)
        address = node.dig("Spec", "Labels", NODE_ADDRESS_LABEL).presence ||
          node.dig("Status", "Addr")
        "#{node_scheme}://#{address}:#{node_port}"
      end

      def tasks_for(service_id)
        filters = MultiJson.dump(service: [ service_id ])
        parse_json(manager_connection.get("/tasks", filters: filters))
      end

      def swarm_network_config(config)
        config.merge(
          "Driver" => "overlay",
          "Attachable" => true,
          "Scope" => "swarm"
        )
      end

      def list_value(value, separator: /\s*,\s*/)
        case value
        when nil then []
        when Array then value.filter_map(&:presence)
        else value.to_s.split(separator).filter_map(&:presence)
        end
      end

      def compact_hash(hash)
        hash.compact.reject { |_, value| value.respond_to?(:empty?) && value.empty? }
      end

      def parse_json(payload)
        Docker::Util.parse_json(payload) || {}
      end
    end
  end
end
