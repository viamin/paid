# frozen_string_literal: true

module AppleVerification
  module SourceLane
    # Inspects the originating paid-agent container before its workspace can
    # become a source lane. Docker's mount table is the authority for this
    # decision; missing container state or an unreadable inspection fails
    # closed so source never crosses the verification boundary unchecked.
    # @spec APPLE-TRANSFER-003
    class HostMountCheck
      InspectionUnavailableError = Class.new(StandardError)

      def self.call(...)
        new(...).call
      end

      def initialize(agent_run)
        @agent_run = agent_run
      end

      def call
        workspace_mounts.any? { |mount| writable_host_workspace_mount?(mount) }
      rescue Docker::Error::DockerError, KeyError, TypeError => error
        raise InspectionUnavailableError, "cannot inspect the paid-agent container mount table: #{error.message}"
      end

      private

      attr_reader :agent_run

      def workspace_mounts
        inspected_container = container
        unless inspected_container.respond_to?(:info)
          raise InspectionUnavailableError, "cannot inspect the paid-agent container mount table"
        end

        mounts = inspected_container.info.fetch("Mounts")
        raise InspectionUnavailableError, "paid-agent container mount table is invalid" unless mounts.is_a?(Array) && mounts.all?(Hash)

        mounts
      end

      def container
        raise InspectionUnavailableError, "paid-agent container is unavailable" if agent_run.container_id.blank?

        Containers.backend_for(agent_run.container_host).get_container(agent_run.container_id)
      end

      def writable_host_workspace_mount?(mount)
        mount["Type"] == "bind" && mount["Destination"] == "/workspace" && mount["RW"] == true
      end
    end
  end
end
