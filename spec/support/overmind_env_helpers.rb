# frozen_string_literal: true

# Shared helpers for specs that verify overmind is invoked in a clean
# (Bundler-free) environment.  Used by bin/dev and bin/dev-update specs.
module OvermindEnvHelpers
  # Returns an env hash that simulates running inside a Bundler-managed
  # wrapper script (e.g. the RubyGems binstub for overmind).
  def bundler_contaminated_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "OVERMIND_SOCKET" => ".overmind.sock",
      "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
      "BUNDLE_BIN_PATH" => "/tmp/fake-bundle-bin",
      "BUNDLER_SETUP" => "/tmp/fake-bundler-setup",
      "BUNDLER_VERSION" => "2.7.2",
      "RUBYLIB" => "/tmp/fake-rubylib",
      "RUBYOPT" => "-r/tmp/fake-bundler/setup",
      "RUBYGEMS_GEMDEPS" => "-"
    }
  end

  # Reads the log written by the overmind stub that records each invocation's
  # command and environment variables.
  def overmind_invocation_log(dir)
    File.read(File.join(dir, "stubbin", "overmind-env.log"))
  end
end
