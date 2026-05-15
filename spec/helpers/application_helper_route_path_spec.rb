# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db, type: :helper do
  describe "#project_agent_runs_collection_path" do
    let(:project) { double(to_param: "1") }

    it "uses the active helper route context before falling back to global url helpers" do
      allow(helper).to receive(:respond_to?).and_call_original
      allow(helper).to receive(:respond_to?).with(:project_agent_runs_path).and_return(true)
      allow(helper).to receive(:public_send)
        .with(:project_agent_runs_path, project)
        .and_return("/projects/1/agent_runs")

      expect(helper.project_agent_runs_collection_path(project)).to eq("/projects/1/agent_runs")
    end

    it "falls back to global url helpers when the helper route is unavailable" do
      route_helpers = Rails.application.routes.url_helpers

      allow(helper).to receive(:respond_to?).and_call_original
      allow(helper).to receive(:respond_to?).with(:project_agent_runs_path).and_return(false)
      allow(route_helpers).to receive(:public_send)
        .with(:project_agent_runs_path, project)
        .and_return("/projects/1/agent_runs")

      expect(helper.project_agent_runs_collection_path(project)).to eq("/projects/1/agent_runs")
    end

    it "falls back to global url helpers when the helper route exists but cannot be called" do
      route_helpers = Rails.application.routes.url_helpers

      allow(helper).to receive(:respond_to?).and_call_original
      allow(helper).to receive(:respond_to?).with(:project_agent_runs_path).and_return(true)
      allow(helper).to receive(:project_agent_runs_path)
        .with(project)
        .and_raise(NoMethodError.new("undefined method `project_agent_runs_path'", :project_agent_runs_path))
      allow(route_helpers).to receive(:public_send)
        .with(:project_agent_runs_path, project)
        .and_return("/projects/1/agent_runs")

      expect(helper.project_agent_runs_collection_path(project)).to eq("/projects/1/agent_runs")
    end
  end
end
