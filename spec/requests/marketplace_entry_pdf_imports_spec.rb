# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MarketplaceEntryPdfImports" do
  let(:account) { create(:account, plan: "professional") }
  let(:user) { create(:user, :member, account: account) }
  let(:uploaded_file) do
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/sample.pdf"), "application/pdf")
  end

  before { sign_in user }

  describe "GET /marketplace_entry_pdf_import/new" do
    it "renders the import form" do
      get new_marketplace_entry_pdf_import_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Import PDF to Team Marketplace")
    end
  end

  describe "POST /marketplace_entry_pdf_import" do
    it "creates the marketplace entry from a PDF" do
      entry = create(:marketplace_entry, account: account, name: "Modern CSS Coach")

      allow(MarketplaceEntries::ImportFromPdf).to receive(:call).and_return(entry)

      post marketplace_entry_pdf_import_path, params: {
        marketplace_entry: {
          name: "Modern CSS Coach",
          entry_type: "skill",
          status: "draft",
          pdf_file: uploaded_file
        }
      }

      expect(response).to redirect_to(marketplace_entry_path(entry))
      expect(flash[:notice]).to eq("Marketplace entry created from PDF.")
    end

    it "rerenders the form when the import fails" do
      allow(MarketplaceEntries::ImportFromPdf).to receive(:call)
        .and_raise(MarketplaceEntries::ImportFromPdf::ImportError, "Choose a PDF file to import.")

      post marketplace_entry_pdf_import_path, params: {
        marketplace_entry: {
          name: "Modern CSS Coach",
          entry_type: "skill",
          status: "draft",
          pdf_file: uploaded_file
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Choose a PDF file to import.")
    end
  end
end
