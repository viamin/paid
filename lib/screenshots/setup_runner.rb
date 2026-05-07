# frozen_string_literal: true

require "open3"
require "shellwords"

module Screenshots
  class SetupRunner
    def call(commands:, repo_path:)
      Array(commands).each do |command|
        stdout, stderr, status = Open3.capture3(command, chdir: repo_path)
        next if status.success?

        raise "Screenshot setup command failed: #{command}\n#{stderr.presence || stdout}"
      end
    end
  end
end
