# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::GitCredentialsController, type: :controller do
  before do
    controller.class.skip_before_action :validate_container_request, raise: false
    controller.class.skip_before_action :set_authenticated_run, raise: false
    controller.class.skip_before_action :verify_proxy_token, raise: false
    controller.class.skip_around_action :with_container_tenant_context, raise: false
  end

  describe "GET show" do
    context "with PAT-backed project" do
      let(:project) { create(:project) }

      before do
        allow(controller).to receive(:authenticated_project).and_return(project)
      end

      it "returns git credentials with PAT token" do
        get :show

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("password=")
        expect(response.body).to include("username=x-access-token")
        expect(response.body).to include("host=github.com")
      end
    end

    context "with app-backed project" do
      let(:key) { OpenSSL::PKey::RSA.new(2048).to_pem }
      let(:project) { create(:project, :with_github_installation) }

      before do
        allow(controller).to receive(:authenticated_project).and_return(project)

        ENV["PAID_AGENT_APP_ID"] = "123"
        ENV["PAID_AGENT_APP_PRIVATE_KEY"] = key

        stub_request(:post, %r{/app/installations/\d+/access_tokens})
          .to_return(status: 201, body: { token: "ghs_short_lived_token" }.to_json)
      end

      after do
        ENV.delete("PAID_AGENT_APP_ID")
        ENV.delete("PAID_AGENT_APP_PRIVATE_KEY")
      end

      it "returns git credentials with installation token" do
        get :show

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("password=ghs_short_lived_token")
      end
    end

    context "without project" do
      before do
        allow(controller).to receive(:authenticated_project).and_return(nil)
      end

      it "returns forbidden" do
        get :show
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
