# frozen_string_literal: true

module AppleVerification
  module Setup
    # Injectable shell-out abstraction so preflight can run under tests
    # without the actual macOS toolchain. The default implementation shells
    # out via `Open3.capture3` so the preflight can be exercised on any
    # operator workstation.
    # @spec APPLE-SETUP-001
    class Shell
      CommandResult = Data.define(:stdout, :stderr, :status) do
        def success?
          status&.success?
        end

        def stdout_lines
          stdout.to_s.split("\n")
        end
      end

      def initialize(capture: method(:capture3))
        @capture = capture
      end

      def run(*argv)
        stdout, stderr, status = @capture.call(*argv)
        CommandResult.new(stdout:, stderr:, status:)
      rescue Errno::ENOENT, Errno::EACCES => error
        CommandResult.new(stdout: "", stderr: "#{error.class.name}: #{error.message}", status: nil)
      end

      def file_read(path)
        File.read(path)
      rescue Errno::ENOENT, Errno::EACCES => error
        "#{error.class.name}: #{error.message}"
      end

      def file_present?(path)
        File.exist?(path)
      rescue StandardError
        false
      end

      def command_path(name)
        stdout, _stderr, status = @capture.call("which", name)
        stdout.to_s.strip if status&.success?
      end

      private

      def capture3(*argv)
        require "open3"
        Open3.capture3(*argv)
      end
    end
  end
end
