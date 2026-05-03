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
      klass = AgentHarness::Providers::Registry.instance.get(harness_key)

      config = AgentHarness::ProviderConfig.new(harness_key)
      config.externally_sandboxed = true

      provider_instance = klass.new(config: config)
      Result.new(**provider_instance.plan_execution(prompt: prompt, **options))
    end

    def call
      Result.new(**harness_provider.plan_execution(prompt: @prompt, provider_runtime: provider_runtime, **@options))
    end

    private

    def harness_provider
      @harness_provider ||= begin
        klass = AgentHarness::Providers::Registry.instance.get(harness_provider_name)
        klass.new
      end
    end

    def harness_provider_name
      ProviderSupport.harness_provider_key_for(@provider.provider_key).to_sym
    end

    def provider_runtime
      @provider.agent_harness_provider_runtime
    end
  end
end
