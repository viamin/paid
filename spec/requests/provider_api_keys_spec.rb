# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ProviderApiKeys" do
  let(:user) { create(:user) }

  describe "GET /provider_api_keys" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get provider_api_keys_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get provider_api_keys_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("LLM API Keys")
      end

      it "shows the user's API keys" do
        create(:provider_api_key, user: user, name: "My Claude Key")
        get provider_api_keys_path
        expect(response.body).to include("My Claude Key")
      end

      it "does not show API keys from other users" do
        other_user = create(:user)
        create(:provider_api_key, user: other_user, name: "Other Key")
        get provider_api_keys_path
        expect(response.body).not_to include("Other Key")
      end

      it "shows the API service type" do
        create(:provider_api_key, user: user, api_service_type: "anthropic")
        get provider_api_keys_path
        expect(response.body).to include("Anthropic")
      end
    end
  end

  describe "GET /provider_api_keys/:id" do
    context "when not authenticated" do
      it "redirects to sign in" do
        api_key = create(:provider_api_key, user: user)
        get provider_api_key_path(api_key)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows the API key details" do
        api_key = create(:provider_api_key, user: user, name: "My Key")
        get provider_api_key_path(api_key)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("My Key")
      end

      it "masks the API key value" do
        api_key = create(:provider_api_key, user: user)
        get provider_api_key_path(api_key)
        expect(response.body).to include("****")
        expect(response.body).not_to include(api_key.api_key.to_s)
      end

      it "does not allow viewing API keys from other users" do
        other_user = create(:user)
        other_key = create(:provider_api_key, user: other_user)
        get provider_api_key_path(other_key)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /provider_api_keys/new" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get new_provider_api_key_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the new form" do
        get new_provider_api_key_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add LLM API Key")
      end

      it "renders API service type options as a select" do
        get new_provider_api_key_path

        expect(response.body).to include('value="openrouter"')
        expect(response.body).to include("OpenRouter")
        expect(response.body).to include('value="anthropic"')
        expect(response.body).to include("Anthropic")
      end
    end
  end

  describe "POST /provider_api_keys" do
    context "when not authenticated" do
      it "redirects to sign in" do
        post provider_api_keys_path, params: { provider_api_key: { name: "Test", api_key: "sk-test-abc123", api_service_type: "anthropic" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      context "with valid parameters" do
        let(:valid_params) do
          { provider_api_key: { name: "My API Key", api_key: "sk-test-abc123def456", api_service_type: "anthropic" } }
        end

        it "creates a new API key" do
          expect {
            post provider_api_keys_path, params: valid_params
          }.to change(ProviderApiKey, :count).by(1)
        end

        it "associates the key with the current user" do
          post provider_api_keys_path, params: valid_params
          expect(ProviderApiKey.last.user).to eq(user)
        end

        it "stores the api_service_type" do
          post provider_api_keys_path, params: valid_params
          expect(ProviderApiKey.last.api_service_type).to eq("anthropic")
        end

        it "redirects to the show page" do
          post provider_api_keys_path, params: valid_params
          expect(response).to redirect_to(provider_api_key_path(ProviderApiKey.last))
        end
      end

      context "with invalid parameters" do
        it "re-renders the form when name is missing" do
          post provider_api_keys_path, params: { provider_api_key: { name: "", api_key: "sk-test-abc", api_service_type: "anthropic" } }
          expect(response).to have_http_status(:unprocessable_content)
        end

        it "re-renders the form when api key is missing" do
          post provider_api_keys_path, params: { provider_api_key: { name: "Test", api_key: "", api_service_type: "anthropic" } }
          expect(response).to have_http_status(:unprocessable_content)
        end

        it "re-renders the form when api_service_type is missing" do
          post provider_api_keys_path, params: { provider_api_key: { name: "Test", api_key: "sk-test-abc", api_service_type: "" } }
          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end
  end

  describe "GET /provider_api_keys/:id/edit" do
    context "when not authenticated" do
      it "redirects to sign in" do
        api_key = create(:provider_api_key, user: user)
        get edit_provider_api_key_path(api_key)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the edit form" do
        api_key = create(:provider_api_key, user: user, name: "My Key")
        get edit_provider_api_key_path(api_key)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Edit LLM API Key")
        expect(response.body).to include("My Key")
      end

      it "does not allow editing API keys from other users" do
        other_user = create(:user)
        other_key = create(:provider_api_key, user: other_user)
        get edit_provider_api_key_path(other_key)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /provider_api_keys/:id" do
    context "when not authenticated" do
      it "redirects to sign in" do
        api_key = create(:provider_api_key, user: user)
        patch provider_api_key_path(api_key), params: { provider_api_key: { name: "Updated" } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "updates the name" do
        api_key = create(:provider_api_key, user: user, name: "Old Name")
        patch provider_api_key_path(api_key), params: { provider_api_key: { name: "New Name" } }
        expect(response).to redirect_to(provider_api_key_path(api_key))
        expect(api_key.reload.name).to eq("New Name")
      end

      it "updates api_service_type" do
        api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
        patch provider_api_key_path(api_key), params: { provider_api_key: { api_service_type: "openrouter" } }
        expect(api_key.reload.api_service_type).to eq("openrouter")
      end

      it "keeps existing API key when api_key param is blank" do
        api_key = create(:provider_api_key, user: user, api_key: "sk-original-key-12345")
        patch provider_api_key_path(api_key), params: { provider_api_key: { name: "Updated", api_key: "" } }
        expect(api_key.reload.api_key).to eq("sk-original-key-12345")
      end

      it "updates the API key when a new value is provided" do
        api_key = create(:provider_api_key, user: user, api_key: "sk-original-key-12345")
        patch provider_api_key_path(api_key), params: { provider_api_key: { api_key: "sk-new-key-67890abcd" } }
        expect(api_key.reload.api_key).to eq("sk-new-key-67890abcd")
      end

      it "re-renders edit on validation failure" do
        api_key = create(:provider_api_key, user: user)
        patch provider_api_key_path(api_key), params: { provider_api_key: { name: "" } }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects invalid api_service_type" do
        api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
        patch provider_api_key_path(api_key), params: { provider_api_key: { api_service_type: "invalid" } }
        expect(response).to have_http_status(:unprocessable_content)
        expect(api_key.reload.api_service_type).to eq("anthropic")
      end

      it "does not allow updating API keys from other users" do
        other_user = create(:user)
        other_key = create(:provider_api_key, user: other_user)
        patch provider_api_key_path(other_key), params: { provider_api_key: { name: "Hacked" } }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /provider_api_keys/:id" do
    context "when not authenticated" do
      it "redirects to sign in" do
        api_key = create(:provider_api_key, user: user)
        delete provider_api_key_path(api_key)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "deletes the API key" do
        api_key = create(:provider_api_key, user: user)
        expect {
          delete provider_api_key_path(api_key)
        }.to change(ProviderApiKey, :count).by(-1)
      end

      it "redirects to the index" do
        api_key = create(:provider_api_key, user: user)
        delete provider_api_key_path(api_key)
        expect(response).to redirect_to(provider_api_keys_path)
        expect(flash[:notice]).to include("deleted")
      end

      it "cannot delete API keys from other users" do
        other_user = create(:user)
        other_key = create(:provider_api_key, user: other_user)
        delete provider_api_key_path(other_key)
        expect(response).to have_http_status(:not_found)
      end

      it "blocks deletion when providers reference the key" do
        api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
        create(:provider, user: user, provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)
        delete provider_api_key_path(api_key)
        expect(response).to redirect_to(provider_api_key_path(api_key))
        expect(flash[:alert]).to include("Cannot delete")
      end
    end
  end
end
