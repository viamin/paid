# frozen_string_literal: true

require "shellwords"

module Containers
  class HarnessExecutor
    KILOCODE_AUTO_FLAGS = %w[--auto --print-logs].freeze
    private_constant :KILOCODE_AUTO_FLAGS

    def initialize(agent_run)
      @agent_run = agent_run
    end

    def execute(command, timeout: nil, env: {}, preparation: nil, **)
      unset_vars, set_vars = partition_env(env)
      effective_command = inject_kilocode_auto_flags(wrapped_command(command, unset_vars))
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = @agent_run.execute_in_container(
        effective_command,
        timeout: timeout,
        stream: false,
        env: set_vars,
        preparation: preparation
      )
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      AgentHarness::CommandExecutor::Result.new(
        stdout: result[:stdout].to_s,
        stderr: result[:stderr].to_s,
        exit_code: result.success? ? (result[:exit_code] || 0) : (result[:exit_code] || 1),
        duration: duration
      )
    end

    def which(binary)
      result = @agent_run.execute_in_container(
        [ "sh", "-c", "command -v -- #{Shellwords.escape(binary.to_s)}" ],
        stream: false,
        env: {},
        preparation: nil
      )

      return unless result.success?

      result[:stdout].to_s.strip.presence
    end

    def available?(binary)
      which(binary).present?
    end

    private

    def wrapped_command(command, unset_vars)
      unset_vars.any? ? command_with_unset_env(command, unset_vars) : command
    end

    def inject_kilocode_auto_flags(command)
      return command unless command.is_a?(Array) && command.length >= 2

      kilo_idx = command.index("kilo")
      return command unless kilo_idx

      run_idx = command.index("run")
      return command unless run_idx && run_idx > kilo_idx

      return command if command.include?("--auto")

      command[0..run_idx] + KILOCODE_AUTO_FLAGS + command[(run_idx + 1)..]
    end

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
