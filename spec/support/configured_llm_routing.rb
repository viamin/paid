# frozen_string_literal: true

module ConfiguredLlmRouting
  ISOLATED_PROVIDER_KEYS = %i[claude cursor codex github_copilot gemini opencode kilocode pi omp].freeze

  def configure_llm_routing(project: nil, account: nil)
    project.save! if project && !project.persisted?
    owner = project&.effective_owner || account&.fallback_owner || create(:user, **(account ? { account: account } : {}))
    owner.save! unless owner.persisted?
    Current.user = owner unless project || account
    runner = owner.runners.kept_only.where(runner_key: "claude").ordered.first ||
      create(:runner, user: owner, runner_key: "claude")
    runner.update!(enabled_for_chat: true, tier_models: { "mid" => { "model_id" => "configured-mid", "provider_id" => 17 } })
    stub_configured_llm_via_conductor
  end

  def stub_configured_llm_via_conductor
    allow(AgentHarness).to receive(:provider_class).and_call_original
    ISOLATED_PROVIDER_KEYS.each do |key|
      klass = AgentHarness.provider_class(key)
      allow(klass).to receive(:new).and_wrap_original do |constructor, **options|
        constructor.call(**options).tap do |provider|
          allow(provider).to receive(:supports_tool_control?).and_return(true)
          allow(provider).to receive(:send_message) do |prompt:, **request_options|
            options = request_options.merge(model: request_options[:provider_runtime]&.model).compact
            AgentHarness.conductor.execute_direct(prompt, **options, provider: key)
          end
        end
      end
    end
  end

  def stub_isolated_llm_via_conductor
    allow(AgentHarness).to receive(:provider_class).and_wrap_original do |method, key|
      klass = method.call(key)
      allow(klass).to receive(:new).and_wrap_original do |constructor, **options|
        constructor.call(**options).tap do |provider|
          next unless options[:executor].is_a?(Containers::StandaloneTextExecutor)

          allow(provider).to receive(:supports_tool_control?).and_return(true)
          allow(provider).to receive(:send_message) do |prompt:, **request_options|
            options = request_options.merge(model: request_options[:provider_runtime]&.model).compact
            AgentHarness.conductor.execute_direct(prompt, **options, provider: key)
          end
        end
      end
      klass
    end
  end

  def stub_isolated_llm_response(response = nil, error: nil)
    @isolated_llm_requests = []
    allow(AgentHarness).to receive(:provider_class).and_wrap_original do |method, key|
      klass = method.call(key)
      allow(klass).to receive(:new).and_wrap_original do |constructor, **options|
        constructor.call(**options).tap do |provider|
          next unless options[:executor].is_a?(Containers::StandaloneTextExecutor)

          allow(provider).to receive(:send_message) do |prompt:, **request_options|
            @isolated_llm_requests << { prompt: prompt, options: request_options, provider: key }
            raise error if error

            response
          end
        end
      end
      klass
    end
  end

  attr_reader :isolated_llm_requests
end

RSpec.configure do |config|
  config.include ConfiguredLlmRouting

  # Existing application-text specs stub the conductor as the external
  # agent_harness boundary. Keep those stubs effective now that Llm::Request
  # reaches that boundary through a disposable-container executor.
  config.before { stub_isolated_llm_via_conductor }
end
