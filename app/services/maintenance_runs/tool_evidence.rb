# frozen_string_literal: true

module MaintenanceRuns
  # Collects bounded, advisory analyzer evidence before the maintenance agent
  # assesses it. Marketplace attachment selection/provisioning stays wholly in
  # RDR-073; this adapter consumes only the resulting run snapshots.
  # @spec MAINT-040 MAINT-041 MAINT-042 MAINT-043 MAINT-044 MAINT-045
  class ToolEvidence
    VERSION_TIMEOUT = 30
    PROVISION_TIMEOUT = 300
    ANALYSIS_TIMEOUT = 120
    DISCOVERY_TIMEOUT = 30
    OUTPUT_LIMIT = 20_000
    MAX_PACKAGE_SCOPES = 10
    ACTIVITY_OVERHEAD = 30
    SCOPED_EXECUTION = 'cd -- "$1" && shift && exec "$@"'
    PACKAGE_DISCOVERY = [ "find", ".", "-type", "f", "(", "-name", "Gemfile", "-o", "-name", "package.json", ")",
      "-not", "-path", "*/node_modules/*", "-not", "-path", "*/vendor/*", "-not", "-path", "*/.git/*", "-print0" ].freeze

    Analysis = Data.define(:name, :command)
    Adapter = Data.define(:name, :ecosystems, :manifest, :provision_command, :version_command, :analyses,
      :configuration_files)
    ADAPTERS = [
      Adapter.new("exhale", [ "ruby" ], "Gemfile", [ "sh", "-lc",
        "ruby -rbundler -e 'lock = Bundler::LockfileParser.new(Bundler.read_file(\"Gemfile.lock\")); exit(lock.specs.any? { |spec| spec.name == \"exhale\" } ? 0 : 1)' && (bundle check || BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3)" ],
        %w[bundle exec exhale --version], [
        Analysis.new("exhale_dry", %w[bundle exec exhale dry --format json]),
        Analysis.new("exhale_complexity", %w[bundle exec exhale complexity --format json])
      ], %w[.exhale.yml .exhale.yaml]),
      Adapter.new("knip", %w[javascript typescript], "package.json", [ "sh", "-lc",
        "node -e 'const p = require(\"./package.json\"); const d = {...p.dependencies, ...p.devDependencies}; process.exit(d.knip && require(\"fs\").existsSync(\"yarn.lock\") ? 0 : 1)' && yarn install --frozen-lockfile --ignore-scripts --silent" ],
        %w[yarn knip --version], [
        Analysis.new("knip", %w[yarn knip --reporter json])
      ], %w[knip.json knip.jsonc knip.ts knip.js package.json])
    ].freeze
    ACTIVITY_TIMEOUT = DISCOVERY_TIMEOUT + (MAX_PACKAGE_SCOPES * ADAPTERS.sum do |adapter|
      PROVISION_TIMEOUT + VERSION_TIMEOUT + (adapter.analyses.size * ANALYSIS_TIMEOUT)
    end) + ACTIVITY_OVERHEAD

    def self.call(...) = new(...).call

    def initialize(run:)
      @run = run
    end

    def call
      checks = analyzer_checks
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

    def analyzer_checks
      adapters = applicable_adapters
      return [] if adapters.empty?

      discovery = execute(PACKAGE_DISCOVERY, DISCOVERY_TIMEOUT)
      return [ discovery_check(discovery) ] unless exit_code(discovery) == 0

      adapters.flat_map { |adapter| collect_packages(adapter, package_scopes(discovery, adapter)) }
    rescue Containers::Provision::Error => error
      [ discovery_check(nil, error:) ]
    end

    def applicable_adapters
      return [] unless run.maintenance_objective == "unnecessary_code"

      languages = Array(run.project.effective_repo_profile["languages"]).map(&:to_s)
      ADAPTERS.select { |adapter| (adapter.ecosystems & languages).any? }
    end

    def package_scopes(discovery, adapter)
      output(discovery).to_s.split("\0").filter_map do |path|
        next unless File.basename(path) == adapter.manifest

        File.dirname(path.delete_prefix("./")).presence || "."
      end.uniq
    end

    def collect_packages(adapter, scopes)
      return [] if scopes.empty?

      available = scopes.first(MAX_PACKAGE_SCOPES).filter_map do |scope|
        version = available_version(adapter, scope)
        [ scope, version ] if version
      end
      return [] if available.empty?

      checks = available.flat_map { |scope, version| collect(adapter, scope, version) }
      checks << package_limit_check(adapter, scopes.size) if scopes.size > MAX_PACKAGE_SCOPES
      checks
    end

    def available_version(adapter, scope)
      provision = execute_scoped(scope, adapter.provision_command, PROVISION_TIMEOUT)
      return unless exit_code(provision) == 0

      version = execute_scoped(scope, adapter.version_command, VERSION_TIMEOUT)
      version if exit_code(version) == 0
    rescue Containers::Provision::Error
      nil
    end

    def package_limit_check(adapter, count)
      { "name" => "#{adapter.name}_package_discovery", "status" => "incomplete",
        "reason" => "package_scope_limit_exceeded", "discovered_package_count" => count,
        "analyzed_package_count" => MAX_PACKAGE_SCOPES }
    end

    def collect(adapter, scope, version)
      adapter.analyses.map do |analysis|
        result = execute_scoped(scope, analysis.command, ANALYSIS_TIMEOUT)
        analyzer_check(adapter, analysis, scope, version, result)
      end
    rescue Containers::Provision::Error => error
      [ { "name" => adapter.name, "status" => "incomplete", "reason" => "execution_unavailable",
          "provenance" => provenance(adapter, scope, nil), "error_class" => error.class.name } ]
    end

    def execute_scoped(scope, command, timeout)
      execute([ "sh", "-lc", SCOPED_EXECUTION, "paid-analyzer", scope, *command ], timeout)
    end

    def execute(command, timeout)
      run.execute_in_execution_environment(command, timeout:, stream: false)
    end

    def discovery_check(result, error: nil)
      reason = error ? "execution_unavailable" : "unexpected_exit_code"
      { "name" => "analyzer_package_discovery", "status" => "incomplete", "reason" => reason,
        "exit_code" => exit_code(result), "output" => output(result), "error_class" => error&.class&.name }.compact
    end

    def analyzer_check(adapter, analysis, scope, version, result)
      status = exit_code(result).in?([ 0, 1 ]) ? "completed" : "incomplete"
      { "name" => analysis.name, "status" => status, "exit_code" => exit_code(result),
        "provenance" => provenance(adapter, scope, version, analysis.command), "output" => output(result),
        "reason" => ("unexpected_exit_code" unless status == "completed") }.compact
    end

    def marketplace_check
      endpoints = Array(run.tool_sidecar_endpoints)
      return if endpoints.empty?

      { "name" => "marketplace_tool_attachments", "status" => "completed", "advisory" => true,
        "provenance" => Array(run.tool_sidecar_snapshot).map { |tool| tool.slice("name", "image", "port", "marketplace_entry_version_id") },
        "endpoints" => endpoints.map { |endpoint| endpoint.slice("name", "url", "port") } }
    end

    def provenance(adapter, scope, version, command = nil)
      { "name" => adapter.name, "version" => output(version),
        "configuration" => { "package_scope" => scope, "searched_files" => adapter.configuration_files },
        "package_scope" => scope, "command" => command, "ecosystems" => adapter.ecosystems }.compact
    end

    def output(result)
      return if result.nil?

      [ result[:stdout], result[:stderr] ].compact.join("\n").truncate(OUTPUT_LIMIT)
    end

    def exit_code(result)
      result&.[](:exit_code)
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
