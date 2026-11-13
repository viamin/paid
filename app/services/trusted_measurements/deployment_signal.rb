# frozen_string_literal: true

require "digest"
require "open3"

module TrustedMeasurements
  # The identity of the revision Paid believes is currently deployed and
  # serving the live data a trusted measurement reads. Production uses the
  # deploy pipeline's environment variable. Development runs from a mounted
  # checkout, whose identity includes HEAD and source changes so a local edit
  # makes earlier evidence stale.
  #
  # A missing signal is not an error on its own: it is recorded on the
  # attempt as an unknown revision, which keeps the resulting evidence from
  # ever being treated as current (see
  # TrustedMeasurementAttempt#current_for_revision?).
  module DeploymentSignal
    ENV_KEY = "PAID_DEPLOYED_REVISION"
    GIT_ENVIRONMENT = {
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_INDEX_FILE" => nil
    }.freeze

    def self.current(root: Rails.root, environment: Rails.env)
      return ENV[ENV_KEY].presence unless environment.to_s == "development"

      head = git_output(root, "rev-parse", "HEAD")
      untracked = git_output(root, "ls-files", "--others", "--exclude-standard", "-z")
      return if [ head, untracked ].any?(&:nil?)

      digest = Digest::SHA256.new
      return unless update_from_git_diff(digest, root)

      untracked.split("\0").sort.each do |name|
        path = File.join(root, name)
        digest.update(name).update("\0")
        if File.symlink?(path)
          digest.update(File.readlink(path))
        else
          File.open(path, "rb") { |file| digest.update(file.read(64 * 1024)) until file.eof? }
        end
        digest.update("\0")
      end
      "development:#{head.strip}:#{digest.hexdigest}"
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      nil
    end

    def self.git_output(root, *arguments)
      output, _error, status = Open3.capture3(GIT_ENVIRONMENT, "git", "-C", root.to_s, *arguments)
      output if status.success?
    end
    private_class_method :git_output

    def self.update_from_git_diff(digest, root)
      Open3.popen2(GIT_ENVIRONMENT, "git", "-C", root.to_s, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD",
        err: File::NULL) do |input, output, process|
        input.close
        digest.update(output.read(64 * 1024)) until output.eof?
        process.value.success?
      end
    end
    private_class_method :update_from_git_diff
  end
end
