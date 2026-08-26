# frozen_string_literal: true

require_relative "../../app/services/screenshots/config_parser"
require_relative "../../app/services/screenshots/capture_targets"
require_relative "capture_orchestrator"

module Screenshots
  # The rake/CI capture path. It captures screenshots only: page load
  # measurement is scoped to the container capture path, which is the one with
  # a run, a pull request, and a per-project ledger to record against.
  # @spec PAGE-LOAD-MEASURE-010
  class Capture
    def self.call(output_dir: "tmp/screenshots", changed_files: [], repo_path: Rails.root.to_s, project: nil)
      new(output_dir:, changed_files:, repo_path:, project:).call
    end

    def initialize(output_dir:, changed_files:, repo_path:, project:)
      @output_dir = output_dir
      @changed_files = Array(changed_files)
      @repo_path = repo_path
      @project = project
    end

    def call
      result = Screenshots::CaptureOrchestrator.call(
        output_dir: @output_dir,
        repo_path: @repo_path,
        project: @project,
        config: legacy_config,
        targets: Screenshots::CaptureTargets.call(changed_files: @changed_files, repo_path: @repo_path)
      )

      raise_capture_error!(result.failures) if result.failures.any?

      result.paths
    end

    private

    def legacy_config
      Screenshots::ConfigParser.from_repo_path(@repo_path, project: @project)
    rescue Screenshots::ConfigError
      Screenshots::Configuration.from_hash(
        "driver" => "cuprite",
        "base_url" => "http://localhost:3000",
        "auth" => {
          "strategy" => "form",
          "login_path" => "/users/sign_in",
          "fields" => {
            "email" => "input[name='user[email]']",
            "password" => "input[name='user[password]']",
            "submit" => "input[name='commit']"
          },
          "credentials" => {
            "email" => "%{user_email}",
            "password" => "%{user_password}"
          }
        },
        "seed" => [
          { "key" => "__all__", "runner" => "Screenshots::SeedData::Paid.call" }
        ],
        "routes" => [ { "path" => "/", "name" => "placeholder" } ]
      )
    end

    def raise_capture_error!(failures)
      raise "Screenshot capture failed:\n  #{failures.join("\n  ")}"
    end
  end
end
