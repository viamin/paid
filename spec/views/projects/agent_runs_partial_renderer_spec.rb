# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects/_agent_runs renderer", :no_db do
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
  end

  let(:project) { AgentRunsPartialRendererFakeProject.new(id: 1, name: "Platform") }

  it "renders through ApplicationController with main-app route helpers available" do
    rendered = ApplicationController.render(
      partial: "projects/agent_runs",
      locals: {
        project: project,
        recent_agent_runs: [],
        stale_agent_runs_count: 0,
        show_stale_cleanup_action: false
      }
    )

    expect(rendered).to include("Recent Agent Runs")
    expect(rendered).to include("/projects/1/agent_runs")
  end
end
