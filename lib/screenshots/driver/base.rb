# frozen_string_literal: true

module Screenshots
  module Driver
    class Base
      def initialize(config:, repo_path: Rails.root.to_s)
        @config = config
        @repo_path = repo_path
      end

      attr_reader :config, :repo_path

      def start_browser
        raise NotImplementedError
      end

      def visit(_url)
        raise NotImplementedError
      end

      def screenshot(name:, path:)
        raise NotImplementedError
      end

      def authenticate(auth_config:)
        raise NotImplementedError
      end

      def wait_for_load
        raise NotImplementedError
      end

      def quit; end

      def current_path
        nil
      end
    end
  end
end
