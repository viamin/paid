# frozen_string_literal: true

require "shellwords"

# Provider-neutral checks backing the RDR-057 no-shared-filesystem runner
# conformance suite. Everything here operates on the runner contract boundary
# ({ExecutionRunners::RunnerHandle}, the input/output manifests, and the
# {ExecutionRunners::Base} interface tokens) so the checks stay independent of
# any concrete execution platform.
#
# @spec CONTAINER-RUNTIME-019
module NoSharedFilesystemConformance
  # Absolute-path substrings: the shape a host-storage assumption takes when
  # it leaks across the control-plane/runner boundary. Scans within strings so
  # embedded host paths in shell snippets, mount flags, or file:// locators
  # are caught, while ordinary URLs and opaque runner references do not match.
  HOST_PATH_PATTERN = %r{(?:(?<=file://)|(?<![\w:/]))(/[\w.-]+(?:/[\w.-]+)*)}

  # Tokens naming the Docker exec / bind-mount / shared-directory concepts the
  # runner contract must not carry (RDR-057). Matched against interface method
  # names, parameter names, and value-object member names. "execution" is
  # allowed, and provider-neutral "execute" lifecycle names stay allowed; the
  # target is Docker's exec transport, not the word family.
  FORBIDDEN_SURFACE_PATTERN = /
    container_id | bind_mount | network_name | host_path |
    worktree(?:_path)? | volume_name | docker |
    shared_dir | host_dir | mount_source | exec(?!ution|ute)
  /x

  # Printed by the fixture workload immediately before it reads its own
  # artifact back over stdout. Artifact production is observed on the runner's
  # output stream rather than on host filesystem state, which a runner that
  # executes inside its own environment never populates.
  FIXTURE_ARTIFACT_MARKER = "CONFORMANCE_ARTIFACT:"

  CONTRACT_VALUE_OBJECTS = [
    ExecutionRunners::RunSpec,
    ExecutionRunners::RunnerHandle,
    ExecutionRunners::ExecutionResult,
    ExecutionRunners::ExecutionStatus,
    ExecutionRunners::NetworkingPolicy,
    ExecutionRunners::ServiceDeclaration,
    ExecutionRunners::ExecutionResources
  ].freeze

  class << self
    # Collects every string in a JSON-native payload that names an absolute
    # filesystem path, excluding the given declarative in-container paths
    # (e.g. the workspace mount point).
    #
    # @param payload [Object] JSON-native Hash/Array/scalar tree
    # @param allowed [Array<String>] absolute paths permitted by declaration
    # @return [Array<String>] offending host-path strings, unique
    def host_path_strings(payload, allowed: [])
      strings = []
      collect_strings(payload, strings)
      strings.uniq
             .flat_map { |value| value.scan(HOST_PATH_PATTERN).flatten }
             .uniq
             .reject { |value| allowed.include?(value) }
    end

    # Shell command for the canonical fixture workload: clone the fixture
    # repository into the provisioned environment, run its entrypoint there,
    # and print the artifact the entrypoint wrote so the evidence returns over
    # the runner's own stdout stream.
    #
    # @param source [String, Pathname] git URL/path the environment clones from
    # @param destination [String, Pathname] checkout path inside the environment
    # @param fixture [Hash] fixture workload definition
    # @return [String] shell command
    def fixture_workload_command(source:, destination:,
                                 fixture: ExecutionRunners::ConformanceSuite.fixture_workload)
      checkout = Shellwords.escape(destination.to_s)
      [
        "git clone --quiet #{Shellwords.escape(source.to_s)} #{checkout}",
        "cd #{checkout}",
        fixture.fetch("entrypoint"),
        "printf '%s' #{Shellwords.escape(FIXTURE_ARTIFACT_MARKER)}",
        "cat #{Shellwords.escape(fixture.fetch('expected_artifact_path'))}"
      ].join(" && ")
    end

    # Whether the given command is the fixture workload. Runner specs whose
    # execution platform is doubled use this at the runner seam to answer with
    # {fixture_workload_stdout} instead of their generic canned output.
    #
    # Matches on the full command shape {fixture_workload_command} builds —
    # the clone, the entrypoint, and the artifact readback — rather than the
    # entrypoint token alone. An entrypoint-only match would still treat a
    # runner regression that dropped the clone step or stopped reading the
    # artifact back over stdout as a legitimate fixture run, silently
    # replacing that broken command with the canned passing output.
    #
    # @param command [String, Array<String>]
    # @return [Boolean]
    def fixture_workload_command?(command, fixture: ExecutionRunners::ConformanceSuite.fixture_workload)
      joined = Array(command).join(" ")

      joined.include?("git clone") &&
        joined.include?(fixture.fetch("entrypoint")) &&
        joined.include?("cat #{Shellwords.escape(fixture.fetch('expected_artifact_path'))}")
    end

    # The stdout the fixture workload produces inside the environment: the
    # token its entrypoint prints, followed by the artifact it wrote, read back
    # over the same stream. A doubled execution platform returns this so the
    # conformance example asserts on runner-streamed output without executing
    # the workload on the host, where it would prove nothing about the runner.
    #
    # @param fixture [Hash] fixture workload definition
    # @return [String]
    def fixture_workload_stdout(fixture: ExecutionRunners::ConformanceSuite.fixture_workload)
      token = fixture.fetch("expected_stdout")
      artifact = { "status" => "ok", "token" => token, "fixture_version" => fixture.fetch("fixture_version") }

      "#{token}\n#{FIXTURE_ARTIFACT_MARKER}#{artifact.to_json}\n"
    end

    # The artifact payload the fixture workload reported back on stdout, or nil
    # when the stream carries no parseable artifact — the shape a runner that
    # never ran the workload inside its environment produces.
    #
    # @param stdout [String]
    # @return [Hash, nil]
    def reported_fixture_artifact(stdout)
      return nil unless stdout.to_s.include?(FIXTURE_ARTIFACT_MARKER)

      JSON.parse(stdout.to_s.split(FIXTURE_ARTIFACT_MARKER, 2).last.to_s.lines.first.to_s)
    rescue JSON::ParserError
      nil
    end

    # Every method name, parameter name, and value-object member name on the
    # provider-neutral runner contract.
    #
    # @return [Array<String>] unique surface tokens
    def contract_surface_tokens
      instance_methods = ExecutionRunners::Base.instance_methods(false)
      singleton_methods = ExecutionRunners::Base.singleton_methods(false)
      parameters = instance_methods.flat_map do |name|
        ExecutionRunners::Base.instance_method(name).parameters.map { |_, param| param }
      end
      parameters += singleton_methods.flat_map do |name|
        ExecutionRunners::Base.method(name).parameters.map { |_, param| param }
      end
      members = CONTRACT_VALUE_OBJECTS.flat_map(&:members)

      (instance_methods + singleton_methods + parameters + members).compact.map(&:to_s).uniq
    end

    # Filters the given surface tokens down to the Docker exec / bind-mount /
    # shared-directory concepts the contract must not carry.
    #
    # @param tokens [Array<String>, Array<Symbol>]
    # @return [Array<String>] offending tokens
    def forbidden_surface_tokens(tokens)
      tokens.select { |token| token.to_s.match?(FORBIDDEN_SURFACE_PATTERN) }
    end

    private

    def collect_strings(value, strings)
      case value
      when Hash then value.each_value { |entry| collect_strings(entry, strings) }
      when Array then value.each { |entry| collect_strings(entry, strings) }
      when String then strings << value
      end
    end
  end
end
