# frozen_string_literal: true

require "rails_helper"
require "rubygems/package"
require "zlib"
require "stringio"

# @spec KNOWLEDGE-OKF-005
RSpec.describe "Projects::OkfExports" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account: account) }
  let(:project) { create(:project, account: account) }
  let(:project_version) { create(:project_version, project:) }
  let(:collector_run) { create(:collector_run, project_version:, collector_type: "okf") }

  before { sign_in user }

  def create_exportable_artifact
    artifact = create(:knowledge_artifact, collector_run:, project:, artifact_type: "okf_concept", identifier: "Auth flows")
    create(:knowledge_chunk, knowledge_artifact: artifact, project:, chunk_type: "definition", content: "Body.")
    artifact
  end

  describe "GET /projects/:project_id/okf_export/new" do
    it "renders the export form with curated types pre-checked" do
      create_exportable_artifact

      get new_project_okf_export_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Export OKF Bundle")
      expect(response.body).to include("okf_export_type_okf_concept")
    end
  end

  describe "POST /projects/:project_id/okf_export" do
    it "streams a tar.gz bundle for the selected artifact types" do
      create_exportable_artifact

      post project_okf_export_path(project), params: { okf_export: { artifact_types: [ "okf_concept" ] } }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/gzip")
      expect(response.headers["Content-Disposition"]).to include("okf-export-#{project.name.parameterize}")

      entries = []
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(response.body))) do |tar|
        tar.each { |entry| entries << entry.full_name }
      end
      expect(entries.length).to eq(1)
    end

    it "rerenders the form with an alert when no artifacts match the selection" do
      post project_okf_export_path(project), params: { okf_export: { artifact_types: [ "okf_concept" ] } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("No exportable knowledge artifacts matched")
    end

    it "rerenders the form with an alert when no artifact types are selected" do
      post project_okf_export_path(project), params: { okf_export: {} }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("select at least one exportable artifact type")
    end
  end
end
