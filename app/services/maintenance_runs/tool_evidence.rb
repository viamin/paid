# frozen_string_literal: true

module MaintenanceRuns
  # Collects bounded, advisory analyzer evidence before the maintenance agent
  # assesses it. Marketplace attachment selection/provisioning stays wholly in
  # RDR-073; this adapter consumes only the resulting run snapshots.
  # @spec MAINT-040 MAINT-041 MAINT-042 MAINT-043 MAINT-044 MAINT-045
  class ToolEvidence
    VERSION_TIMEOUT = 30
    ANALYSIS_TIMEOUT = 120
    OUTPUT_LIMIT = 20_000
    ACTIVITY_OVERHEAD = 30

    Adapter = Data.define(:name, :ecosystems, :version_command, :command, :configuration)
    ADAPTERS = [
      Adapter.new("exhale", [ "ruby" ], %w[bundle exec exhale --version],
        %w[bundle exec exhale --format json], "project Exhale configuration"),
      Adapter.new("knip", %w[javascript typescript], %w[yarn knip --version],
        %w[yarn knip --reporter json], "project Knip configuration")
    ].freeze
    ACTIVITY_TIMEOUT = (ADAPTERS.size * (VERSION_TIMEOUT + ANALYSIS_TIMEOUT)) + ACTIVITY_OVERHEAD

    def self.call(...) = new(...).call

    def initialize(run:)
      @run = run
    end

    def call
      checks = applicable_adapters.filter_map { |adapter| collect(adapter) }
      sidecar_check = marketplace_check
      checks << sidecar_check if sidecar_check
      {
        completed_checks: checks.select { |check| check["status"] == "completed" },
        incomplete_checks: checks.select { |check| check["status"] == "incomplete" },
        prompt_context: prompt_context(checks)
      }
    end

    private

    attr_reader :run

    def applicable_adapters
      return [] unless run.maintenance_objective == "unnecessary_code"

      languages = Array(run.project.effective_repo_profile["languages"]).map(&:to_s)
      ADAPTERS.select { |adapter| (adapter.ecosystems & languages).any? }
    end

    def collect(adapter)
      version = execute(adapter.version_command, VERSION_TIMEOUT)
      return unavailable_check(adapter, version) unless exit_code(version).zero?

      analysis = execute(adapter.command, ANALYSIS_TIMEOUT)
      analyzer_check(adapter, version, analysis)
    rescue Containers::Provision::Error => error
      { "name" => adapter.name, "status" => "incomplete", "reason" => "execution_unavailable",
        "provenance" => provenance(adapter, nil), "error_class" => error.class.name }
    end

    def execute(command, timeout)
      run.execute_in_execution_environment(command, timeout:, stream: false)
    end

    def unavailable_check(adapter, version)
      { "name" => adapter.name, "status" => "incomplete", "reason" => "unavailable_or_unsupported",
        "provenance" => provenance(adapter, version), "output" => output(version) }
    end

    def analyzer_check(adapter, version, analysis)
      status = exit_code(analysis).in?([ 0, 1 ]) ? "completed" : "incomplete"
      { "name" => adapter.name, "status" => status, "exit_code" => exit_code(analysis),
        "provenance" => provenance(adapter, version), "output" => output(analysis),
        "reason" => ("unexpected_exit_code" unless status == "completed") }.compact
    end

    def marketplace_check
      endpoints = Array(run.tool_sidecar_endpoints)
      return if endpoints.empty?

      { "name" => "marketplace_tool_attachments", "status" => "completed", "advisory" => true,
        "provenance" => Array(run.tool_sidecar_snapshot).map { |tool| tool.slice("name", "image", "port", "marketplace_entry_version_id") },
        "endpoints" => endpoints.map { |endpoint| endpoint.slice("name", "url", "port") } }
    end

    def provenance(adapter, version)
      { "name" => adapter.name, "version" => output(version), "configuration" => adapter.configuration,
        "command" => adapter.command, "ecosystems" => adapter.ecosystems }
    end

    def output(result)
      return if result.nil?

      [ result[:stdout], result[:stderr] ].compact.join("\n").truncate(OUTPUT_LIMIT)
    end

    def exit_code(result)
      result[:exit_code].to_i
    end

    def prompt_context(checks)
      return if checks.empty?

      <<~CONTEXT
        ## Tool-assisted maintenance evidence (advisory)
        The following checks ran inside this run's isolated checkout. Treat their output as candidate evidence only: verify callers, framework entry points, repository intent, deliberate duplication, dynamic callbacks, and externally consumed APIs through agent_harness before recommending a change. Tool matches never authorize a blocking gate, automatic repair, extraction, or deletion.

        #{checks.to_json}
      CONTEXT
    end
  end
end
