# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyReviewsController, :no_db, type: :controller do
  describe "#edit_params" do
    before do
      allow(controller).to receive(:params).and_return(request_params)
    end

    context "when content is submitted as JSON text" do
      let(:request_params) do
        ActionController::Parameters.new(
          strategy_version: {
            change_notes: "Reviewer edit",
            reasoning: "Tighten rollout guardrails",
            content: %({"mode":"hybrid"})
          }
        )
      end

      it "parses the JSON into a hash" do
        expect(controller.send(:edit_params)).to eq(
          change_notes: "Reviewer edit",
          reasoning: "Tighten rollout guardrails",
          content: { "mode" => "hybrid" }
        )
      end
    end

    context "when content is submitted as nested parameters" do
      let(:request_params) do
        ActionController::Parameters.new(
          strategy_version: {
            change_notes: "Reviewer edit",
            reasoning: "Tighten rollout guardrails",
            content: {
              mode: "hybrid",
              retry_policy: { attempts: 3 }
            }
          }
        )
      end

      it "preserves the object instead of dropping it from strong params" do
        expect(controller.send(:edit_params)).to eq(
          change_notes: "Reviewer edit",
          reasoning: "Tighten rollout guardrails",
          content: {
            "mode" => "hybrid",
            "retry_policy" => { "attempts" => 3 }
          }
        )
      end
    end

    context "when content JSON is invalid" do
      let(:request_params) do
        ActionController::Parameters.new(
          strategy_version: {
            content: "{invalid"
          }
        )
      end

      it "raises a clear validation error" do
        expect { controller.send(:edit_params) }.to raise_error(ArgumentError, "content must be valid JSON")
      end
    end

    context "when content parses to a non-object" do
      let(:request_params) do
        ActionController::Parameters.new(
          strategy_version: {
            content: %(["hybrid"])
          }
        )
      end

      it "rejects the payload" do
        expect { controller.send(:edit_params) }.to raise_error(ArgumentError, "content must be an object")
      end
    end
  end
end
