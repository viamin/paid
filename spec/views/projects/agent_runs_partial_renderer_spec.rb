# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects/_agent_runs", :no_db, type: :view do
  before do
    stub_const("AgentRunsPartialRendererFakeProject", Class.new do
      extend ActiveModel::Naming
      include ActiveModel::Conversion

      attr_reader :id, :name

      def initialize(id:, name:)
        @id = id
        @name = name
      end

      def persisted?
        true
      end

      def to_key
        [ id ]
      end

      def to_param
        id.to_s
      end
  end)
    allow(view).to receive(:project_agent_runs_collection_path).with(instance_of(AgentRunsPartialRendererFakeProject)).and_return("/projects/1/agent_runs")
    allow(view).to receive(:cleanup_stale_runs_project_member_path).with(instance_of(AgentRunsPartialRendererFakeProject)).and_return("/projects/1/cleanup_stale_runs")
  end

  let(:project) { AgentRunsPartialRendererFakeProject.new(id: 1, name: "Platform") }

  it "renders without relying on controller renderer route helper availability" do
    render partial: "projects/agent_runs", locals: {
      project: project,
      recent_agent_runs: [],
      stale_agent_runs_count: 0,
      show_stale_cleanup_action: false
    }

    expect(rendered).to include("Recent Agent Runs")
    expect(rendered).to include("/projects/1/agent_runs")
  end

  it "renders the stale cleanup action without relying on route helper availability" do
    render partial: "projects/agent_runs", locals: {
      project: project,
      recent_agent_runs: [],
      stale_agent_runs_count: 2,
      show_stale_cleanup_action: true
    }

    expect(rendered).to include("/projects/1/cleanup_stale_runs")
    expect(rendered).to include("Clean Up Stale Runs")
  end
end
