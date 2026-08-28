# frozen_string_literal: true

module Containers
  module Backends
    class Base
      def remote?
        false
      end

      def identifier
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def supports_host_paths?
        true
      end

      def owns_host?(_host)
        false
      end

      def ping
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def system_info
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def capacity_snapshot_list_container_options
        {}
      end

      # Returns all container_host values this backend may have persisted.
      # Used by cleanup jobs to scope queries to the correct backend.
      # Backends with multiple hosts (e.g., swarm) should override this.
      def all_host_identifiers
        [ identifier ]
      end

      def container_host_for(_container)
        identifier
      end

      def get_container(_id)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def create_container(_config)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def start_container(_container)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def stop_container(_container, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def delete_container(_container, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def exec_in_container(_container, _command, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def container_stats(_container, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def container_logs(_container, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def list_containers(**)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      # Whether any container currently references the given image tag. The
      # default implementation uses the Docker Engine container-list
      # "ancestor" filter, which single-daemon backends (local/remote)
      # support natively. Backends without an ancestor-filterable
      # container-list endpoint (e.g. Swarm, whose /services API has no
      # such filter) must override this with a backend-appropriate check.
      def image_in_use?(tag)
        list_containers(filters: { ancestor: [ tag ] }.to_json).any?
      end

      # Lists containers that serve live-preview traffic for the tunnel
      # server. The default filters by the preview tunnel label, which works
      # for any Docker-backed backend. A non-Docker backend (e.g. a future
      # remote runner) overrides this to return its own preview containers —
      # or an empty set when previews run on a separate substrate the tunnel
      # server cannot inspect.
      def list_preview_containers
        list_containers(filters: { label: [ "#{Previews::TunnelManager::PREVIEW_TUNNEL_LABEL}=true" ] }.to_json)
      end

      def get_network(_name)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def create_network(_name, _config)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def pull_image(_config)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def get_image(_name)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      # Returns one label hash per backing daemon that holds the requested
      # image reference. Single-daemon backends naturally return one entry;
      # multi-daemon backends (e.g. swarm) override this so callers can make
      # cluster-wide freshness decisions instead of trusting a single image
      # object.
      def image_label_sets(name)
        [ get_image(name).info["Labels"] || {} ]
      end

      # Builds an image from a Dockerfile string (no build context files —
      # language layers install from the network, so the context is the
      # Dockerfile alone). Streams build output to the optional block.
      # @param dockerfile [String] full Dockerfile content
      # @param opts [Hash] Docker /build query options (:t, :buildargs,
      #   :labels, :nocache, ...) — callers that build a layered chain of
      #   images MUST pass :t and chain subsequent layers FROM that tag, not
      #   from the return value's id: multi-host backends build
      #   independently per host and only the shared tag is guaranteed to
      #   resolve consistently everywhere.
      # @return [Docker::Image, Array<Docker::Image>] the built image, or one
      #   built image per host for backends that build on multiple hosts
      def build_image(_dockerfile, _opts = {})
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def list_images(_opts = {})
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      # Removes an image (or a single tag of it) by reference.
      def delete_image(_name, **_opts)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def list_volumes
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def create_volume(_name, _options = nil, host: nil, **_keyword_options)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def get_volume(_name, host: nil)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def delete_volume(_volume, **)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end
    end
  end
end
