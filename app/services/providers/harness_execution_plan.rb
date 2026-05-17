# frozen_string_literal: true

module Providers
  class HarnessExecutionPlan
    Result = Struct.new(:command, :env, :preparation, keyword_init: true)

    def initialize(provider:, prompt:, options: {}, provider_runtime: nil)
      @provider = provider
      @prompt = prompt
      @options = options
      @provider_runtime = provider_runtime
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
    def self.for_provider_key(provider_key:, prompt:, options: {}, provider_runtime: nil)
      harness_key = ProviderSupport.harness_provider_key_for(provider_key).to_sym
      provider_instance = build_harness_provider(harness_key)
      kwargs = { prompt: prompt, **options }
      kwargs[:provider_runtime] = provider_runtime if provider_runtime
      Result.new(**provider_instance.plan_execution(**kwargs))
    end

    def call
      Result.new(**harness_provider.plan_execution(prompt: @prompt, provider_runtime: provider_runtime, **@options))
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
      ProviderSupport.harness_provider_key_for(@provider.provider_key).to_sym
    end

    def provider_runtime
      @provider_runtime || @provider.agent_harness_provider_runtime
    end
  end
end
