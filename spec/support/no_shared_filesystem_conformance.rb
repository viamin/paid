# frozen_string_literal: true

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
  # allowed; the target is Docker's exec transport, not the word family.
  FORBIDDEN_SURFACE_PATTERN = /
    container_id | bind_mount | network_name | host_path |
    worktree(?:_path)? | volume_name | docker |
    shared_dir | host_dir | mount_source | exec(?!ution)
  /x

  CONTRACT_VALUE_OBJECTS = [
    ExecutionRunners::RunSpec,
    ExecutionRunners::RunnerHandle,
    ExecutionRunners::ExecutionResult,
    ExecutionRunners::ExecutionStatus,
    ExecutionRunners::NetworkingPolicy,
    ExecutionRunners::ServiceDeclaration,
    ExecutionRunners::ComputeRequirements
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
