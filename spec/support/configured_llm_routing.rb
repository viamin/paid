# frozen_string_literal: true

module ConfiguredLlmRouting
  def configure_llm_routing(project: nil, account: nil)
    project.save! if project && !project.persisted?
    owner = project&.effective_owner || account&.fallback_owner || create(:user, **(account ? { account: account } : {}))
    owner.save! unless owner.persisted?
    allow(AgentHarness).to receive(:provider_class).and_wrap_original do |method, key|
      klass = method.call(key)
      allow(klass).to receive(:new).and_wrap_original do |constructor, **options|
        constructor.call(**options).tap { |provider| allow(provider).to receive(:supports_tool_control?).and_return(true) }
      end
      klass
    end
    Current.user = owner unless project || account
    runner = owner.runners.kept_only.where(runner_key: "claude").ordered.first ||
      create(:runner, user: owner, runner_key: "claude")
    runner.update!(enabled_for_chat: true, tier_models: { "mid" => { "model_id" => "configured-mid", "provider_id" => 17 } })
  end

  def stub_isolated_llm_via_conductor
    allow(AgentHarness).to receive(:provider_class).and_wrap_original do |method, key|
      klass = method.call(key)
      allow(klass).to receive(:new).and_wrap_original do |constructor, **options|
        constructor.call(**options).tap do |provider|
          allow(provider).to receive(:send_message) do |prompt:, **request_options|
            AgentHarness.conductor.execute_direct(prompt, **request_options, provider: key)
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
end
