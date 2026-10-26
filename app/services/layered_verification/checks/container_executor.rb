# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Runs a documented command inside the audit run's isolated execution
    # environment. The executor never runs project code on the Paid host: when
    # the run has no container, it reports that the command could not run
    # instead of executing it locally.
    #
    # @spec LAYERED-VERIFY-022
    class ContainerExecutor
      Execution = Data.define(:exit_code, :stdout, :stderr, :unavailable_reason) do
        def available? = unavailable_reason.nil?
      end

      DEFAULT_TIMEOUT = 600

      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:, timeout: DEFAULT_TIMEOUT, backend: nil)
        @agent_run = agent_run
        @timeout = timeout
        @backend = backend
      end

      def call(command, working_dir: nil)
        container = resolve_container
        return unavailable("the audit run has no isolated execution environment") unless container

        script = working_dir ? "cd #{Shellwords.escape(working_dir)} && #{command}" : command
        stdout, stderr, exit_code = backend.exec_in_container(
          container,
          [ "sh", "-lc", script ],
          user: "agent",
          wait: timeout
        )
        Execution.new(
          exit_code: exit_code.to_i,
          stdout: Array(stdout).join,
          stderr: Array(stderr).join,
          unavailable_reason: nil
        )
      rescue StandardError => e
        Rails.logger.warn(
          message: "layered_verification.container_exec_failed",
          agent_run_id: agent_run&.id,
          error_class: e.class.name,
          error: e.message
        )
        unavailable("the command could not be executed in the isolated environment")
      end

      private

      attr_reader :agent_run, :timeout

      def backend
        @backend ||= Containers.backend
      end

      def resolve_container
        identifier = agent_run&.container_id
        return if identifier.blank?

        backend.get_container(identifier)
      end

      def unavailable(reason)
        Execution.new(exit_code: nil, stdout: "", stderr: "", unavailable_reason: reason)
      end
    end
  end
end
