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
      TASK_READY_TIMEOUT = 30
      TASK_POLL_INTERVAL = 0.25

      VolumeHandle = Struct.new(:backend, :id, :host, :labels, keyword_init: true) do
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

        def update!(service:, task:)
          @service = service
          @task = task
          rebuild_info!
          self
        end

        def update_task!(task)
          @task = task
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

      def remote?
        false
      end

      def supports_host_paths?
        false
      end

      def owns_host?(host)
        cached_node_hostnames.include?(host.to_s)
      end

      def all_host_identifiers
        cached_node_hostnames.to_a + [ identifier ]
      end

      def ping
        manager_connection.ping
      end

      def system_info
        aggregate_system_info(healthy_nodes)
      end

      def capacity_snapshot_list_container_options
        { include_node_containers: true }
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
        wait_for_runnable_task!(container)
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
        include_node_containers = options.delete(:include_node_containers)
        query = options[:filters].present? ? { filters: options[:filters] } : {}
        services = parse_json(manager_connection.get("/services", query))
        tasks_by_service = tasks_for_services(services.map { |service| service.fetch("ID") })
        service_task_container_ids = tasks_by_service.values.flatten.filter_map do |task|
          task.dig("Status", "ContainerStatus", "ContainerID").presence
        end.to_set

        containers = services.map do |service|
          ServiceHandle.new(
            backend: self,
            service: service,
            task: primary_task_for(service.fetch("ID"), tasks: tasks_by_service[service.fetch("ID")])
          )
        end

        return containers unless include_node_containers

        containers + list_node_local_containers(options:, exclude_ids: service_task_container_ids)
      end

      # Swarm's /services endpoint has no "ancestor" filter (only
      # id/label/mode/name), so the container-list based default in {Base}
      # can't detect usage here — it either raises or silently ignores the
      # filter and returns unrelated services. Compare each service's task
      # template image reference instead. Swarm resolves a pushed image's
      # tag to a `tag@digest` reference on the running service, so match on
      # the tag portion only; combo images build and run locally per node
      # with no registry to resolve against, so they keep the plain tag.
      def image_in_use?(tag)
        parse_json(manager_connection.get("/services")).any? do |service|
          service.dig("Spec", "TaskTemplate", "ContainerSpec", "Image").to_s.split("@").first == tag
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

      def get_image(name)
        nodes = healthy_nodes
        raise Docker::Error::NotFoundError, "Image #{name} not found: no healthy swarm nodes available" if nodes.empty?

        image = nil
        nodes.each do |node|
          current_image = Docker::Image.get(name, {}, node_connection(node))
          image ||= current_image
        rescue Docker::Error::NotFoundError => error
          raise Docker::Error::NotFoundError, "Image #{name} not found on swarm node #{node_hostname(node) || node.fetch('ID', 'unknown')}: #{error.message}"
        end
        image
      end

      def image_label_sets(name)
        healthy_node_images(name).map { |image| image.info["Labels"] || {} }
      end

      # Builds the image on every healthy node so any node can run it. Docker::Image.build
      # tars the Dockerfile per call, so each node gets its own request body.
      def build_image(dockerfile, opts = {}, &block)
        nodes = healthy_nodes
        raise Docker::Error::NotFoundError, "Image #{opts[:t] || "unknown"} not built: no healthy swarm nodes available" if nodes.empty?

        nodes.map do |node|
          Docker::Image.build(dockerfile, opts, node_connection(node), &block)
        end
      end

      # Combo images build independently per node (see {ComboImageBuilder}),
      # so the same tag legitimately carries a different image ID on every
      # node. Callers (e.g. {ComboImageBuilder.combo_images}) key off
      # RepoTags, not IDs, so dedupe on tag to avoid surfacing the same tag
      # once per node.
      def list_images(opts = {})
        seen_tags = Set.new
        healthy_nodes.each_with_object([]) do |node, images|
          Docker::Image.all(opts, node_connection(node)).each do |image|
            tags = image.info["RepoTags"] || []
            next if tags.present? && tags.all? { |tag| seen_tags.include?(tag) }

            seen_tags.merge(tags)
            images << image
          end
        end
      end

      # Combo tags can be missing from some nodes (see {#list_images}), so a
      # per-node NotFoundError is expected skew, not a failure: skip it and
      # keep deleting on the remaining nodes so partially converged clusters
      # can still clean themselves up.
      def delete_image(name, **opts)
        healthy_nodes.each do |node|
          Docker::Image.remove(name, opts, node_connection(node))
        rescue Docker::Error::NotFoundError
          next
        end
      end

      def list_volumes
        healthy_nodes.flat_map do |node|
          Docker::Volume.all({}, node_connection(node)).map do |volume|
            VolumeHandle.new(backend: self, id: volume.id, host: node_hostname(node), labels: volume.info["Labels"] || {})
          end
        end
      end

      def create_volume(name, _options = nil, host: nil, **_keyword_options)
        VolumeHandle.new(backend: self, id: name, host: host)
      end

      def get_volume(name, host: nil)
        return VolumeHandle.new(backend: self, id: name, host: host) if host.present?

        node = healthy_nodes.find do |candidate|
          Docker::Volume.get(name, {}, node_connection(candidate))
          true
        rescue Docker::Error::NotFoundError
          false
        end
        raise Docker::Error::NotFoundError, "Volume #{name} not found" unless node

        VolumeHandle.new(backend: self, id: name, host: node_hostname(node))
      end

      def delete_volume(volume, **options)
        node = node_by_hostname(volume.host) || raise(Docker::Error::NotFoundError, "Swarm node #{volume.host.inspect} not found")
        Docker::Volume.get(volume.id, {}, node_connection(node)).remove(**options)
      end

      def healthy_node_images(name)
        nodes = healthy_nodes
        raise Docker::Error::NotFoundError, "Image #{name} not found: no healthy swarm nodes available" if nodes.empty?

        nodes.map do |node|
          Docker::Image.get(name, {}, node_connection(node))
        rescue Docker::Error::NotFoundError => error
          raise Docker::Error::NotFoundError, "Image #{name} not found on swarm node #{node_hostname(node) || node.fetch('ID', 'unknown')}: #{error.message}"
        end
      end

      def inspect_service(id)
        parse_json(manager_connection.get("/services/#{id}"))
      end

      def primary_task_for(service_id, tasks: nil)
        choose_primary_task(tasks || tasks_for(service_id))
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
              "CapabilityAdd" => capability_setting(config, host_config, "CapAdd"),
              "CapabilityDrop" => capability_setting(config, host_config, "CapDrop"),
              "Privileges" => privileges_spec(config, host_config)
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
          "NanoCPUs" => nano_cpus(host_config["CpuQuota"], host_config["CpuPeriod"]),
          "Pids" => host_config["PidsLimit"]
        )

        compact_hash("Limits" => limits.presence)
      end

      def capability_setting(config, host_config, key)
        config[key].presence || host_config[key]
      end

      def privileges_spec(config, host_config)
        security_opts = Array(config["SecurityOpt"]) | Array(host_config["SecurityOpt"])
        no_new_privs = security_opts.any? { |opt| opt.match?(/\Ano-new-privileges\s*[:=]\s*true\z/i) }

        compact_hash("NoNewPrivileges" => no_new_privs.presence)
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
        mount_flags = parsed.reject { |part| part.match?(/\A(mode|size)=/) }

        compact_hash(
          "Mode" => mode&.to_i(8),
          "SizeBytes" => size && parse_size(size),
          "Options" => mount_flags.presence
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
        if container.respond_to?(:service_id)
          latest_task = primary_task_for(service_id(container))
          container.update_task!(latest_task) if container.respond_to?(:update_task!)
          return latest_task if latest_task
        end

        container.task if container.respond_to?(:task)
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
        all_nodes.select do |node|
          node.dig("Spec", "Availability") == "active" &&
            node.dig("Status", "State") == "ready"
        end
      end

      def aggregate_system_info(nodes)
        Array(nodes).each_with_object({ "NCPU" => 0, "MemTotal" => 0 }) do |node, aggregate|
          info = Docker.info(node_connection(node))
          aggregate["NCPU"] += info.fetch("NCPU", 0).to_i
          aggregate["MemTotal"] += info.fetch("MemTotal", 0).to_i
        end
      end

      def all_nodes
        parse_json(manager_connection.get("/nodes"))
      end

      def cached_node_hostnames
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @node_hostnames_expires_at.nil? || now >= @node_hostnames_expires_at
          @cached_node_hostnames = all_nodes.map { |node| node_hostname(node) }.compact.to_set
          @node_hostnames_expires_at = now + NODE_HOSTNAME_CACHE_TTL
        end

        @cached_node_hostnames
      end

      def inspect_node(id)
        parse_json(manager_connection.get("/nodes/#{id}"))
      end

      def node_by_hostname(hostname)
        all_nodes.find { |node| node_hostname(node) == hostname.to_s }
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

      def list_node_local_containers(options:, exclude_ids:)
        docker_options = options.except(:filters)
        docker_options[:all] = options[:all] if options.key?(:all)

        healthy_nodes.flat_map do |node|
          Docker::Container.all(docker_options, node_connection(node)).reject do |container|
            exclude_ids.include?(container.id) || swarm_managed_container?(container.info)
          end
        end
      end

      def swarm_managed_container?(info)
        labels = info.fetch("Labels", {}).presence || info.dig("Config", "Labels") || {}
        labels["com.docker.swarm.service.id"].present? || labels["com.docker.swarm.task.id"].present?
      end

      def tasks_for(service_id)
        tasks_for_services([ service_id ]).fetch(service_id, [])
      end

      def tasks_for_services(service_ids)
        return {} if service_ids.empty?

        filters = MultiJson.dump(service: service_ids)
        parse_json(manager_connection.get("/tasks", filters: filters)).group_by { |task| task["ServiceID"] }
      end

      def choose_primary_task(tasks)
        Array(tasks).max_by { |task| [ task_priority(task), task.dig("Version", "Index").to_i ] }
      end

      def task_priority(task)
        return 2 if runnable_task?(task)
        return 1 if active_task?(task)

        0
      end

      def runnable_task?(task)
        task.present? &&
          active_task?(task) &&
          task.dig("Status", "ContainerStatus", "ContainerID").present?
      end

      def active_task?(task)
        return false if task.blank?

        task.dig("DesiredState") == "running" || task.dig("Status", "State") == "running"
      end

      def wait_for_runnable_task!(container)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TASK_READY_TIMEOUT

        loop do
          service = inspect_service(service_id(container))
          task = primary_task_for(service.fetch("ID"))
          container.update!(service:, task:)
          return container if runnable_task?(task)

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise Docker::Error::DockerError,
              "Swarm service #{service.fetch("ID")} did not reach a runnable task within #{TASK_READY_TIMEOUT} seconds"
          end

          sleep(TASK_POLL_INTERVAL)
        end
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
