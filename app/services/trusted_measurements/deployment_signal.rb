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

    def self.current(root: Rails.root, environment: Rails.env)
      return ENV[ENV_KEY].presence unless environment.to_s == "development"

      head = git_output(root, "rev-parse", "HEAD")
      diff = git_output(root, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD")
      untracked = git_output(root, "ls-files", "--others", "--exclude-standard", "-z")
      return if [ head, diff, untracked ].any?(&:nil?)

      digest = Digest::SHA256.new
      digest.update(diff)
      untracked.split("\0").sort.each do |name|
        path = File.join(root, name)
        digest.update(name).update("\0")
        digest.update(File.symlink?(path) ? File.readlink(path) : File.binread(path))
        digest.update("\0")
      end
      "development:#{head.strip}:#{digest.hexdigest}"
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
      nil
    end

    def self.git_output(root, *arguments)
      output, _error, status = Open3.capture3("git", *arguments, chdir: root.to_s)
      output if status.success?
    end
    private_class_method :git_output
  end
end
