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

      def get_network(_name)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def create_network(_name, _config)
        raise NotImplementedError, "#{self.class} must implement ##{__method__}"
      end

      def pull_image(_config)
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
