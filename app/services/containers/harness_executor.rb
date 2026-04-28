# frozen_string_literal: true

require "shellwords"

module Containers
  # Adapts container-based command execution to the AgentHarness::CommandExecutor
  # interface, allowing agent-harness smoke tests to run inside provisioned
  # Docker containers transparently.
  #
  # @example
  #   test_run.with_container do |run|
  #     executor = Containers::HarnessExecutor.new(run)
  #     provider.smoke_test(timeout: 60, executor: executor)
  #   end
  class HarnessExecutor
    def initialize(agent_run)
      @agent_run = agent_run
    end

    # Executes a command inside the container, conforming to the
    # AgentHarness::CommandExecutor#execute contract.
    #
    # @param command [Array<String>, String] command to execute
    # @param timeout [Integer, nil] timeout in seconds
    # @param env [Hash] environment variables (nil values trigger unset)
    # @param preparation [ExecutionPreparation, nil] request-scoped bootstrap
    # @return [AgentHarness::CommandExecutor::Result]
    def execute(command, timeout: nil, env: {}, preparation: nil, **)
      unset_vars, set_vars = partition_env(env)
      wrapped_command = unset_vars.any? ? command_with_unset_env(command, unset_vars) : command

      result = @agent_run.execute_in_container(
        wrapped_command,
        timeout: timeout,
        stream: false,
        env: set_vars,
        preparation: preparation
      )

      AgentHarness::CommandExecutor::Result.new(
        stdout: result[:stdout].to_s,
        stderr: result[:stderr].to_s,
        exit_code: result.success? ? (result[:exit_code] || 0) : (result[:exit_code] || 1),
        duration: 0.0
      )
    end

    # Always returns a truthy path so harness binary-availability checks pass.
    # The actual binary availability is determined by the container image.
    def which(binary)
      "/usr/local/bin/#{binary}"
    end

    def available?(_binary)
      true
    end

    private

    def partition_env(env)
      unset = []
      set = {}

      env.each do |key, value|
        if value.nil?
          unset << key.to_s
        else
          set[key.to_s] = value.to_s
        end
      end

      [ unset, set ]
    end

    def command_with_unset_env(command, unset_vars)
      if command.is_a?(Array)
        [ "env", *unset_vars.flat_map { |var| [ "-u", var ] }, *command ]
      else
        unset_flags = unset_vars.map { |var| "-u #{Shellwords.shellescape(var)}" }.join(" ")
        [ "sh", "-c", "env #{unset_flags} #{command}" ]
      end
    end
  end
end
