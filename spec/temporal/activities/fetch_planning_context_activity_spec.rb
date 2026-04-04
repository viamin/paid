# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::FetchPlanningContextActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, title: "Add user auth", body: "Implement OAuth login") }

  describe "#execute" do
    let(:search_results) do
      {
        results: [
          { title: "Auth module", content: "OAuth implementation details" },
          { title: "User model", content: "User schema and validations" }
        ],
        meta: { mode: "semantic", total: 2 }
      }
    end

    before do
      allow(Knowledge::Search).to receive(:call).and_return(search_results)
    end

    it "returns context with issue details and knowledge snippets" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      context = result[:context]
      expect(context[:issue_title]).to eq("Add user auth")
      expect(context[:issue_body]).to include("Implement OAuth login")
      expect(context[:project_name]).to eq(project.name)
      expect(context[:knowledge_snippets]).to have_attributes(size: 2)
      expect(context[:knowledge_results_count]).to eq(2)
    end

    it "calls Knowledge::Search with the issue content" do
      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(Knowledge::Search).to have_received(:call).with(
        project: project,
        query: a_string_including("Add user auth"),
        mode: "semantic",
        limit: described_class::MAX_CONTEXT_RESULTS
      )
    end

    context "when knowledge search fails" do
      before do
        allow(Knowledge::Search).to receive(:call).and_raise(StandardError.new("search unavailable"))
      end

      it "returns empty knowledge snippets" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:context][:knowledge_snippets]).to eq([])
        expect(result[:context][:knowledge_results_count]).to eq(0)
      end
    end

    it "raises RecordNotFound for invalid project" do
      expect {
        activity.execute(project_id: -1, issue_id: issue.id)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
