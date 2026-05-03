# frozen_string_literal: true

module Providers
  class HarnessExecutionPlan
    Result = Struct.new(:command, :env, :preparation, keyword_init: true)

    def initialize(provider:, prompt:, options: {})
      @provider = provider
      @prompt = prompt
      @options = options
    end

    def self.call(...)
      new(...).call
    end

    # Builds an execution plan for a provider identified by its app-level key
    # (e.g. "claude", "codex") without requiring a Provider model record.
    # Used for subscription-auth and standard providers that don't have a
    # per-user Provider entry.
    #
    # Container-executed providers are always externally sandboxed (the
    # agent Docker container is the sandbox), so this is passed through to
    # the harness provider so provider-specific nested sandbox mechanisms
    # (e.g. Codex bubblewrap) are bypassed automatically.
    #
    # @param provider_key [String] app-level provider key
    # @param prompt [String] the prompt to execute
    # @param options [Hash] options forwarded to the harness provider
    # @return [Result] command, env, and preparation
    def self.for_provider_key(provider_key:, prompt:, options: {})
      harness_key = ProviderSupport.harness_provider_key_for(provider_key).to_sym
      capture = CaptureExecutor.new

      klass = AgentHarness.provider_class(harness_key)
      config = AgentHarness.build_config(harness_key)
      config.externally_sandboxed = true

      provider_instance = klass.new(executor: capture, config: config)
      provider_instance.send_message(prompt: prompt, **options)

      Result.new(command: capture.command, env: capture.env, preparation: capture.preparation)
    end

    def call
      capture = CaptureExecutor.new
      provider_instance = build_harness_provider(executor: capture)
      provider_instance.send_message(prompt: @prompt, provider_runtime: provider_runtime, **@options)

      Result.new(command: capture.command, env: capture.env, preparation: capture.preparation)
    end

    private

    def build_harness_provider(executor:)
      klass = AgentHarness.provider_class(harness_provider_name)
      config = AgentHarness.build_config(harness_provider_name)
      config.externally_sandboxed = true

      klass.new(executor: executor, config: config)
    end

    def harness_provider_name
      ProviderSupport.harness_provider_key_for(@provider.provider_key).to_sym
    end

    def provider_runtime
      @provider.agent_harness_provider_runtime
    end

    # Executor that captures command, env, and preparation without executing.
    # Used to extract the execution plan from send_message without running
    # the actual CLI command.
    class CaptureExecutor
      attr_reader :command, :env, :preparation

      def execute(command, env: {}, preparation: nil, **)
        @command = command
        @env = env
        @preparation = preparation
        AgentHarness::CommandExecutor::Result.new(stdout: "", stderr: "", exit_code: 0)
      end
    end
  end
end
