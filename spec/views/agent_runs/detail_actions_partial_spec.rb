# frozen_string_literal: true

require "rails_helper"

RSpec.describe "agent_runs/_detail_actions", :no_db, type: :view do
  let(:project) { Struct.new(:id).new(1) }
  let(:agent_run) do
    Struct.new(:id, :project, :status, :error_message, :diagnosis_status, keyword_init: true) do
      def finished? = true

      def paused? = false

      def auth_expired? = false

      def auth_provider = nil

      def waiting_recovery? = status == "waiting_recovery"
    end.new(
      id: 123,
      project: project,
      status: "failed",
      error_message: nil,
      diagnosis_status: nil
    )
  end
  let(:retry_runner_options) do
    [
      { runner_key: "claude", label: "Anthropic Claude CLI", current: true },
      { runner_key: "cursor", label: "Cursor AI", current: false }
    ]
  end

  before do
    allow(view).to receive(:dom_id).with(agent_run, :retry_menu_button).and_return("agent_run_123_retry_menu_button")
    allow(view).to receive(:dom_id).with(agent_run, :retry_menu).and_return("agent_run_123_retry_menu")
    allow(view).to receive(:retry_project_agent_run_path).with(project, agent_run).and_return("/projects/1/agent_runs/123/retry")
    allow(view).to receive(:diagnose_error_project_agent_run_path).with(project, agent_run).and_return("/projects/1/agent_runs/123/diagnose_error")
  end

  it "renders retry runner values in the select control" do
    render partial: "agent_runs/detail_actions", locals: {
      agent_run: agent_run,
      show_retry: true,
      retry_provider_options: retry_runner_options
    }

    fragment = Nokogiri::HTML.fragment(rendered)
    runner_values = fragment.css('form[action="/projects/1/agent_runs/123/retry"] select[name="runner"] option')
      .map { |option| option["value"] }

    expect(rendered).to include("Cursor AI")
    expect(rendered).to include("Anthropic Claude CLI (current)")
    expect(runner_values).to include("cursor")
    expect(runner_values).to include("claude")
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "pre-renders the recovery action with a live status visibility hook" do
    agent_run.status = "waiting_recovery"
    allow(view).to receive(:retry_source_closure_project_agent_run_path).and_return("/projects/1/agent_runs/123/retry_source_closure")

    render partial: "agent_runs/detail_actions", locals: { agent_run:, show_retry: true }

    fragment = Nokogiri::HTML.fragment(rendered)
    action = fragment.at_css("[data-when-waiting-recovery]")
    expect(action).to be_present
    expect(action).not_to have_attribute("hidden")
  end
end
