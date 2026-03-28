# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CheckKnowledgeStalenessActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    context "when project exists" do
      let(:project) { create(:project) }
      let(:detection_result) do
        {
          stale: true,
          current_sha: "b" * 40,
          last_collected_sha: "a" * 40,
          changed_files: [ "app/models/user.rb" ],
          stale_artifacts_count: 2,
          collection_enqueued: true
        }
      end

      before do
        allow(Knowledge::Staleness::Detector).to receive(:call)
          .with(project: project)
          .and_return(detection_result)
      end

      it "returns detection result with project_id" do
        result = activity.execute(project_id: project.id)
        expect(result[:stale]).to be true
        expect(result[:current_sha]).to eq("b" * 40)
        expect(result[:stale_artifacts_count]).to eq(2)
        expect(result[:collection_enqueued]).to be true
        expect(result[:project_id]).to eq(project.id)
      end
    end

    context "when project is missing" do
      it "returns consistent shape with project_missing flag" do
        result = activity.execute(project_id: -1)
        expect(result[:stale]).to be false
        expect(result[:project_missing]).to be true
        expect(result[:project_id]).to eq(-1)
        expect(result[:current_sha]).to be_nil
        expect(result[:changed_files]).to eq([])
        expect(result[:stale_artifacts_count]).to eq(0)
        expect(result[:collection_enqueued]).to be false
      end
    end

    context "when detector raises an error" do
      let(:project) { create(:project) }

      before do
        allow(Knowledge::Staleness::Detector).to receive(:call)
          .and_raise(StandardError, "unexpected error")
      end

      it "returns consistent shape with error message" do
        result = activity.execute(project_id: project.id)
        expect(result[:stale]).to be false
        expect(result[:error]).to eq("unexpected error")
        expect(result[:project_id]).to eq(project.id)
        expect(result[:current_sha]).to be_nil
        expect(result[:changed_files]).to eq([])
        expect(result[:stale_artifacts_count]).to eq(0)
        expect(result[:collection_enqueued]).to be false
      end
    end
  end
end
