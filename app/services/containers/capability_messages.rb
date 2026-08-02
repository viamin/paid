# frozen_string_literal: true

module Containers
  module CapabilityMessages
    class << self
      def unavailable_for(capability)
        case capability
        when "failed"
          "Workspace tools are unavailable because the workspace container failed to prepare."
        when "stopped"
          "Workspace tools are unavailable because the workspace container is stopped."
        else
          "Workspace tools are still preparing. Retry shortly or fall back to inline tools."
        end
      end

      def notice_for(capability)
        case capability
        when "failed"
          "Workspace tools are currently unavailable because the workspace container failed to prepare. Use inline tools until the workspace is restored."
        when "stopped"
          "Workspace tools are currently unavailable because the workspace container is stopped. Use inline tools until the workspace is started again."
        end
      end
    end
  end
end
