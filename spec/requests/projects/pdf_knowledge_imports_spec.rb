# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::PdfKnowledgeImports" do
  let(:account) { create(:account, plan: "professional") }
  let(:user) { create(:user, :admin, account: account) }
  let(:project) { create(:project, account: account) }
  let(:uploaded_file) do
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/sample.pdf"), "application/pdf")
  end

  before { sign_in user }

  describe "GET /projects/:project_id/pdf_knowledge_import/new" do
    it "renders the import form" do
      get new_project_pdf_knowledge_import_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Import PDF to Project Knowledge")
    end
  end

  describe "POST /projects/:project_id/pdf_knowledge_import" do
    it "imports the PDF and redirects back to the project" do
      allow(Knowledge::PdfImports::ImportToProject).to receive(:call).and_return(
        artifact_identifier: "Modern CSS"
      )

      post project_pdf_knowledge_import_path(project), params: { pdf_import: { pdf_file: uploaded_file } }

      expect(response).to redirect_to(project_path(project))
      expect(flash[:notice]).to eq("Imported Modern CSS into the project knowledge base.")
    end

    it "rerenders the form when the import fails" do
      allow(Knowledge::PdfImports::ImportToProject).to receive(:call)
        .and_raise(Knowledge::PdfImports::ImportError, "Only PDF uploads are supported.")

      post project_pdf_knowledge_import_path(project), params: { pdf_import: { pdf_file: uploaded_file } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Only PDF uploads are supported.")
    end
  end
end
