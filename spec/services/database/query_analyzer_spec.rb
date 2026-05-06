# frozen_string_literal: true

require "rails_helper"

RSpec.describe Database::QueryAnalyzer do
  describe ".analyze" do
    it "collects query statistics during a block" do
      project = create(:project)

      output = described_class.analyze("test") do
        Project.find(project.id)
      end

      analysis = output[:analysis]
      expect(analysis[:label]).to eq("test")
      expect(analysis[:total_queries]).to be >= 1
      expect(analysis[:total_duration_ms]).to be >= 0
      expect(analysis[:query_distribution]).to include("SELECT" => be >= 1)
      expect(analysis[:recommendations]).to be_an(Array)
    end

    it "detects repeated SELECT patterns" do
      project = create(:project)
      create_list(:agent_run, 4, project: project)

      output = described_class.analyze("n_plus_one_test") do
        project.agent_runs.each { |r| r.project }
      end

      analysis = output[:analysis]
      expect(analysis[:total_queries]).to be >= 1
    end

    it "returns the block result" do
      output = described_class.analyze("result_test") do
        42
      end

      expect(output[:result]).to eq(42)
    end

    it "logs analysis results" do
      allow(Rails.logger).to receive(:info)

      described_class.analyze("log_test") { Project.count }

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "database.query_analysis",
          component: "database",
          label: "log_test"
        )
      )
    end
  end
end
