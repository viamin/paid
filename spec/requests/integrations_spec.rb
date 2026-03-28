# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Integrations" do
  let(:user) { create(:user) }

  describe "GET /integrations" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get integrations_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the integration cards for current and planned credentials" do
        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Integrations")
        expect(response.body).to include("GitHub")
        expect(response.body).to include("Linear")
        expect(response.body).to include("Provider Credentials")
        expect(response.body).to include("GitHub Signing")
        expect(response.body).to include("GitLab")
        expect(response.body).to include("Jira")
      end

      it "shows configured counts per card from both legacy and generic credentials" do
        create(:github_token, account: user.account)
        create(:linear_token, account: user.account)
        create(:integration_credential, account: user.account, created_by: user)

        get integrations_path

        document = Nokogiri::HTML(response.body)

        cards = document.css('[data-testid="integration-card"]')

        github_card = cards.detect { |c| c.css("h3").any? { |h| h.text.strip == "GitHub" } }
        expect(github_card).to be_present
        expect(github_card.text).to include("1 connection configured")

        linear_card = cards.detect { |c| c.css("h3").any? { |h| h.text.strip == "Linear" } }
        expect(linear_card).to be_present
        expect(linear_card.text).to include("1 connection configured")

        provider_card = cards.detect { |c| c.css("h3").any? { |h| h.text.strip == "Provider Credentials" } }
        expect(provider_card).to be_present
        expect(provider_card.text).to include("1 connection configured")
      end
    end
  end
end
