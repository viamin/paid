# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::DeriveHints, :no_db do
  before { allow(Llm::TextMode).to receive(:options).and_return(mode: :text) }

  let(:route_struct) { Struct.new(:name, :path) }
  let(:routes) do
    [
      route_struct.new("dashboard", "/dashboard"),
      route_struct.new("sign_in", "/users/sign_in")
    ]
  end
  let(:agent_run) do
    instance_double(
      AgentRun,
      id: 7,
      agent_summary: "Redesigned the dashboard summary cards."
    )
  end

  def stub_llm(output, success: true)
    response = instance_double(AgentHarness::Response, success?: success, output: output)
    allow(AgentHarness).to receive(:send_message).and_return(response)
  end

  describe ".call" do
    it "returns and persists sanitized hints for known routes" do
      stub_llm({ "dashboard" => { "summary" => "New weekly cost card", "selector" => "[data-testid='cost']" } }.to_json)
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes, changed_files: [ "app/views/dashboard/show.html.erb" ])

      expect(result).to eq(
        "dashboard" => { "summary" => "New weekly cost card", "selector" => "[data-testid='cost']" }
      )
      expect(agent_run).to have_received(:update!).with(screenshot_hints: result)
    end

    it "passes the route catalog, summary, and changed files to the LLM" do
      stub_llm("{}")
      allow(agent_run).to receive(:update!)

      described_class.call(agent_run: agent_run, routes: routes, changed_files: [ "app/views/dashboard/show.html.erb" ])

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("dashboard — /dashboard", "Redesigned the dashboard", "app/views/dashboard/show.html.erb"),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT,
        tools: :none,
        mode: :text
      )
    end

    it "drops routes that are not in the configured catalog" do
      stub_llm({ "nonexistent" => { "summary" => "x" }, "dashboard" => { "summary" => "real" } }.to_json)
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result.keys).to eq([ "dashboard" ])
    end

    it "drops entries without a usable summary" do
      stub_llm({ "dashboard" => { "summary" => "  " }, "sign_in" => { "selector" => ".x" } }.to_json)
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result).to be_empty
    end

    it "omits a blank selector" do
      stub_llm({ "dashboard" => { "summary" => "changed", "selector" => "" } }.to_json)
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result["dashboard"]).to eq("summary" => "changed")
    end

    it "drops an over-long or multi-line selector but keeps the summary" do
      stub_llm({
        "dashboard" => { "summary" => "changed", "selector" => "a" * 250 },
        "sign_in" => { "summary" => "also changed", "selector" => "div\nspan" }
      }.to_json)
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result["dashboard"]).to eq("summary" => "changed")
      expect(result["sign_in"]).to eq("summary" => "also changed")
    end

    it "tolerates a fenced JSON response" do
      stub_llm("```json\n{\"dashboard\": {\"summary\": \"fenced\"}}\n```")
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result["dashboard"]).to eq("summary" => "fenced")
    end

    it "returns empty hints (without raising) on malformed JSON" do
      stub_llm("not json at all")
      allow(agent_run).to receive(:update!)

      result = described_class.call(agent_run: agent_run, routes: routes)

      expect(result).to eq({})
    end

    it "returns empty hints when the LLM call fails" do
      stub_llm("", success: false)
      allow(agent_run).to receive(:update!)

      expect(described_class.call(agent_run: agent_run, routes: routes)).to eq({})
    end

    it "returns empty hints without calling the LLM when there are no routes" do
      allow(AgentHarness).to receive(:send_message)

      expect(described_class.call(agent_run: agent_run, routes: [])).to eq({})
      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "swallows persistence failures and returns empty hints" do
      stub_llm({ "dashboard" => { "summary" => "x" } }.to_json)
      allow(agent_run).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(AgentRun.new))

      expect(described_class.call(agent_run: agent_run, routes: routes)).to eq({})
    end
  end
end
