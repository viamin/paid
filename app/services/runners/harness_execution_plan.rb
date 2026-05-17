# frozen_string_literal: true

module Runners
  class HarnessExecutionPlan
    Result = Struct.new(:command, :env, :preparation, keyword_init: true)

    def initialize(runner:, prompt:, options: {})
      @runner = runner
      @prompt = prompt
      @options = options
    end

    def self.call(...)
      new(...).call
    end

    # Builds an execution plan for a runner identified by its app-level key
    # (e.g. "claude", "codex") without requiring a Runner model record.
    # Used for subscription-auth and standard runners that don't have a
    # per-user Runner entry.
    #
    # Container-executed runners are always externally sandboxed (the
    # agent Docker container is the sandbox), so this is passed through to
    # the harness provider so provider-specific nested sandbox mechanisms
    # (e.g. Codex bubblewrap) are bypassed automatically.
    #
    # @param runner_key [String] app-level runner key
    # @param prompt [String] the prompt to execute
    # @param options [Hash] options forwarded to the harness provider
    # @return [Result] command, env, and preparation
    def self.for_runner_key(runner_key:, prompt:, options: {})
      harness_key = RunnerSupport.harness_runner_key_for(runner_key).to_sym
      provider_instance = build_harness_provider(harness_key)
      Result.new(**provider_instance.plan_execution(prompt: prompt, **options))
    end

    def call
      Result.new(**harness_provider.plan_execution(prompt: @prompt, provider_runtime: runner_runtime, **@options))
    end

    private

    def self.build_harness_provider(harness_key)
      klass = AgentHarness.provider_class(harness_key)
      config = AgentHarness.build_config(harness_key)
      config.externally_sandboxed = true

      klass.new(config: config)
    end
    private_class_method :build_harness_provider

    def harness_provider
      @harness_provider ||= self.class.send(:build_harness_provider, harness_provider_name)
    end

    def harness_provider_name
      RunnerSupport.harness_runner_key_for(@runner.runner_key).to_sym
    end

    def runner_runtime
      @runner.agent_harness_runner_runtime
    end
  end
end
