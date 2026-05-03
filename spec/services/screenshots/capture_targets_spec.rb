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

    it "maps existing prompt review screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/prompt_reviews/show.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "prompt_review_show" ])
    end

    it "maps existing knowledge screens instead of treating them as unmapped UI" do
      targets = described_class.call(changed_files: [ "app/views/knowledge/search/project_search.html.erb" ])

      expect(targets.map(&:slug)).to eq([ "project_knowledge_search" ])
    end

    it "maps helper files that do not follow the default helper-to-view naming convention" do
      targets = described_class.call(changed_files: [ "app/helpers/workflow_helper.rb" ])

      expect(targets.map(&:slug)).to eq([ "workflow_status" ])
    end
  end
end
