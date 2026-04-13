# frozen_string_literal: true

module Providers
  class HarnessExecutionPlan
    Result = Struct.new(:command, :env, :preparation, keyword_init: true)

    def initialize(provider:, prompt:)
      @provider = provider
      @prompt = prompt
    end

    def self.call(...)
      new(...).call
    end

    def call
      harness_provider.send_message(prompt: @prompt, provider_runtime: provider_runtime)

      Result.new(
        command: capture_executor.command,
        env: capture_executor.env,
        preparation: capture_executor.preparation
      )
    end

    private

    def harness_provider
      @harness_provider ||= begin
        klass = AgentHarness::Providers::Registry.instance.get(harness_provider_name)
        klass.new(executor: capture_executor)
      end
    end

    def capture_executor
      @capture_executor ||= ExecutorCapture.new
    end

    def harness_provider_name
      ProviderSupport.harness_provider_key_for(@provider.provider_key).to_sym
    end

    def provider_runtime
      @provider.agent_harness_provider_runtime
    end

    class ExecutorCapture
      attr_reader :command, :env, :preparation

      def execute(command, env: {}, preparation: nil, **)
        @command = command
        @env = env
        @preparation = preparation

        AgentHarness::CommandExecutor::Result.new(
          stdout: "",
          stderr: "",
          exit_code: 0,
          duration: 0.0
        )
      end
    end
  end
end
