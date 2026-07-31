# frozen_string_literal: true

require "open3"
require "tempfile"

module Screenshots
  class SetupRunner
    def initialize
      @script_paths = []
    end

    def call(commands:, repo_path:)
      Array(commands).each do |command|
        stdout, stderr, status = Open3.capture3("sh", script_path_for(command), chdir: repo_path)
        next if status.success?

        raise "Screenshot setup command failed: #{command}\n#{stderr.presence || stdout}"
      end
    ensure
      @script_paths.each(&:close!)
      @script_paths.clear
    end

    private

    def script_path_for(command)
      content = command.to_s
      raise ArgumentError, "Screenshot setup command cannot be blank" if content.blank?

      script = Tempfile.new("screenshot-setup")
      @script_paths << script

      script.write(content)
      script.flush
      File.chmod(0o700, script.path)
      script.path
    end
  end
end
