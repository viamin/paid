# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::CaptureTargets do
  describe ".call" do
    it "maps locale changes to shared UI targets" do
      targets = described_class.call(changed_files: [ "config/locales/devise.en.yml" ])

      expect(targets.map(&:slug)).to include("sign_in", "dashboard", "projects")
    end

    it "maps project-scoped views to project-specific routes" do
      targets = described_class.call(changed_files: [ "app/views/projects/quality_dashboards/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_quality_dashboard" ])
    end

    it "maps resource edit screens to representative edit routes" do
      targets = described_class.call(changed_files: [ "app/views/service_containers/edit.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "service_container_edit" ])
    end

    it "raises when a changed UI file has no route mapping" do
      expect {
        described_class.call(changed_files: [ "app/views/prompt_reviews/show.html.erb" ])
      }.to raise_error(described_class::UnmappedUiChangeError, /prompt_reviews\/show\.html\.erb/)
    end
  end
end
