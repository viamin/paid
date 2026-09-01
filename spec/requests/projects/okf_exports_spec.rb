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

  def create_artifact_with_chunks(artifact_type:, chunk_statuses:, identifier: "Auth flows")
    artifact = create(:knowledge_artifact, collector_run:, project:, artifact_type:, identifier:)
    chunk_statuses.each_with_index do |status, index|
      create(:knowledge_chunk, knowledge_artifact: artifact, project:, chunk_type: "definition",
        content: "Body #{index}.", status:, sequence: index)
    end
    artifact
  end

  describe "GET /projects/:project_id/okf_export/new" do
    it "renders the export form with curated types pre-checked" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "active" ])

      get new_project_okf_export_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Export OKF Bundle")
      expect(response.body).to include("okf_export_type_okf_concept")
    end

    it "renders a non-Turbo form so the browser downloads the tar.gz instead of navigating" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "active" ])

      get new_project_okf_export_path(project)

      form = Nokogiri::HTML(response.body).at_css("form[action*='okf_export']")
      expect(form).not_to be_nil
      expect(form["data-turbo"]).to eq("false")
    end

    it "omits artifact types whose matching artifacts have no active chunks" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "redacted" ])
      create_artifact_with_chunks(artifact_type: "route", chunk_statuses: [ "active" ], identifier: "Users route")

      get new_project_okf_export_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("okf_export_type_okf_concept")
      expect(response.body).to include("okf_export_type_route")
    end
  end

  describe "POST /projects/:project_id/okf_export" do
    it "streams a tar.gz bundle for the selected artifact types" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "active" ])

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

    it "does not set a truncation header when the export is complete" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "active" ])

      post project_okf_export_path(project), params: { okf_export: { artifact_types: [ "okf_concept" ] } }

      expect(response.headers["X-Okf-Export-Truncated"]).to be_nil
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

    it "records an audit event once the archive has been produced" do
      create_artifact_with_chunks(artifact_type: "okf_concept", chunk_statuses: [ "active" ])

      expect {
        post project_okf_export_path(project), params: { okf_export: { artifact_types: [ "okf_concept" ] } }
      }.to change(KnowledgeAuditEvent, :count).by(1)

      event = KnowledgeAuditEvent.last
      expect(event.event_type).to eq("okf_bundle_exported")
      expect(event.actor_type).to eq("user")
      expect(event.actor_id).to eq(user.id.to_s)
      expect(event.details).to include(
        "artifact_types" => [ "okf_concept" ], "exported_count" => 1, "skipped_count" => 0, "truncated_types" => []
      )
    end

    it "does not record an audit event when no artifacts match the selection" do
      expect {
        post project_okf_export_path(project), params: { okf_export: { artifact_types: [ "okf_concept" ] } }
      }.not_to change(KnowledgeAuditEvent, :count)
    end
  end
end
