# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::AdoptionModeGuard do
  describe "#call" do
    let(:account) { create(:account) }

    context "observe_only mode" do
      let(:project) { create(:project, account: account, interop_settings: { "adoption_mode" => "observe_only" }) }

      it "permits viewing metrics" do
        expect(described_class.call(project: project, action: :view_metrics)).to be true
      end

      it "blocks external run ingestion" do
        expect(described_class.call(project: project, action: :ingest_external_runs)).to be false
      end

      it "blocks executing runs" do
        expect(described_class.call(project: project, action: :execute_runs)).to be false
      end
    end

    context "advisory mode" do
      let(:project) { create(:project, account: account, interop_settings: { "adoption_mode" => "advisory" }) }

      it "permits importing config" do
        expect(described_class.call(project: project, action: :import_config)).to be true
      end

      it "permits ingesting external runs" do
        expect(described_class.call(project: project, action: :ingest_external_runs)).to be true
      end

      it "blocks executing runs" do
        expect(described_class.call(project: project, action: :execute_runs)).to be false
      end
    end

    context "review_only mode" do
      let(:project) { create(:project, account: account, interop_settings: { "adoption_mode" => "review_only" }) }

      it "permits reviewing runs" do
        expect(described_class.call(project: project, action: :review_runs)).to be true
      end

      it "blocks executing runs" do
        expect(described_class.call(project: project, action: :execute_runs)).to be false
      end
    end

    context "full_execution mode" do
      let(:project) { create(:project, account: account, interop_settings: { "adoption_mode" => "full_execution" }) }

      it "permits executing runs" do
        expect(described_class.call(project: project, action: :execute_runs)).to be true
      end

      it "permits managing connectors" do
        expect(described_class.call(project: project, action: :manage_connectors)).to be true
      end
    end
  end

  describe ".permitted_actions_for" do
    it "returns cumulative permissions across modes" do
      observe = described_class.permitted_actions_for("observe_only")
      advisory = described_class.permitted_actions_for("advisory")
      review = described_class.permitted_actions_for("review_only")
      full = described_class.permitted_actions_for("full_execution")

      expect(advisory - observe).not_to be_empty
      expect(review - advisory).not_to be_empty
      expect(full - review).not_to be_empty
    end
  end
end
