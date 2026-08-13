# frozen_string_literal: true

require "rails_helper"

class RunnerQuotaNavSpecUser
end

class RunnerQuotaNavSpecRunner
  def id; end

  def display_name; end

  def user; end

  def state_key; end

  def to_param; end
end

class RunnerQuotaNavSpecState
  def updated_at; end

  def rate_limited_until; end
end

RSpec.describe Notifications::Rules::RunnerQuotaExhausted, :no_db do
  let(:rule) { described_class.new }
  let(:user) { instance_double(RunnerQuotaNavSpecUser) }
  let(:runner) do
    instance_double(
      RunnerQuotaNavSpecRunner,
      id: 123,
      display_name: "Claude",
      user: user,
      state_key: "claude",
      to_param: "123"
    )
  end
  let(:state) do
    instance_double(
      RunnerQuotaNavSpecState,
      updated_at: 20.minutes.ago,
      rate_limited_until: 30.minutes.from_now
    )
  end

  before do
    rule.instance_variable_set(:@quota_states, { runner.id => state })
    rule.instance_variable_set(:@blocked_run_counts, { runner.id => 4 })
  end

  it "targets the runners navigation section for runner settings links" do
    payload = rule.send(:build, runner)

    expect(payload[:nav_section]).to eq("runners")
    expect(payload[:action_url]).to eq("/runners/123/edit")
    expect(payload[:description]).to include("open runner settings at /runners/123/edit")
  end
end
