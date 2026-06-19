require "rails_helper"

RSpec.describe "Rotation Debug" do
  it "shows what's happening in the executor" do
    user = create(:user)
    user_setting = user.settings
    api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
    
    high_current = create(:llm_model, :free, model_id: "free-high-current", display_name: "hc", tier: "high", capability_score: 7.0)
    high_other = create(:llm_model, :free, model_id: "free-high-other", display_name: "ho", tier: "high", capability_score: 5.0)
    mid_model = create(:llm_model, :free, model_id: "free-mid", display_name: "m", tier: "mid", capability_score: 4.0)
    
    runner = user.runners.create!(
      runner_key: Runner::OPENROUTER_FREE_RUNNER_KEY,
      auth_type: "api_key",
      provider_api_key: api_key,
      tier_model_ids: {
        "high" => high_current.model_id,
        "mid" => mid_model.model_id,
        "low" => mid_model.model_id
      }
    )
    
    allow(Knowledge::RunnerSelector).to receive(:for_chat)
      .with(user_setting: user_setting)
      .and_return([ Runner::OPENROUTER_FREE_RUNNER_KEY, "openai" ])
    
    allow(FreeModels::Rotation).to receive(:call) do |args|
      puts "FreeModels::Rotation.call with: runner_id=#{args[:runner]&.id}, current_model_id=#{args[:current_model_id]}, current_tier=#{args[:current_tier]}"
      real_result = FreeModels::Rotation.call(**args.except(:runner).merge(runner: args[:runner].reload))
      puts "Real Rotation result: rotated=#{real_result.rotated?}, model_id=#{real_result.model_id}"
      real_result
    end
    
    executor = Knowledge::RunnerExecutor.new(user_setting: user_setting, operation: :chat)
    attempt = 0
    
    result = executor.execute do |r|
      attempt += 1
      puts "Attempt #{attempt}: runner=#{r}"
      if r == Runner::OPENROUTER_FREE_RUNNER_KEY && attempt == 1
        raise AgentHarness::RateLimitError, "rate limited"
      end
      "response from #{r}"
    end
    
    puts "result: #{result.inspect}"
    puts "final tier_model_ids: #{runner.reload.tier_model_ids.inspect}"
    
    expect(true).to be(true)
  end
end
