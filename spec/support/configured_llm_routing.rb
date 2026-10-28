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
end

RSpec.configure do |config|
  config.include ConfiguredLlmRouting
end
