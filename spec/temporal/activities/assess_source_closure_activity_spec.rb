# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AssessSourceClosureActivity do
  let(:project) { create(:project) }
  let(:run) { create(:agent_run, project:, issue: create(:issue, project:)) }

  # @spec PARTIAL-CLOSEOUT-044
  it "exports transport assessment failures as retryable Temporal failures" do
    %w[timeout transport_error unsuccessful_response].each do |category|
      failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category:)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

      expect { described_class.new.execute(agent_run_id: run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error).to be_retryable
          expect(error.details).to eq([ { "category" => category } ])
        end
    end
  end

  # @spec PARTIAL-CLOSEOUT-044
  it "fails closed for authentication and invalid-response categories" do
    %w[authentication_unavailable invalid_json invalid_assessment].each do |category|
      failure = Llm::AnalyzePartialCloseout::AssessmentFailure.new("assessment failed", category:)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(failure)

      expect { described_class.new.execute(agent_run_id: run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |error| expect(error).not_to be_retryable }
    end
  end
end
