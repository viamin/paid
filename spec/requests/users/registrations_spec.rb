# frozen_string_literal: true

require "rails_helper"

RSpec.describe "User Registrations" do
  describe "GET /users/sign_up" do
    it "renders the sign up page" do
      get new_user_registration_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Create your account")
      expect(response.body).to include("Account name")
    end
  end

  describe "POST /users" do
    context "with valid parameters" do
      let(:valid_params) do
        {
          user: {
            account_name: "My Company",
            name: "John Doe",
            email: "john@example.com",
            password: "password123",
            password_confirmation: "password123"
          }
        }
      end

      it "creates a new user and account" do
        expect {
          post user_registration_path, params: valid_params
        }.to change(User, :count).by(1)
          .and change(Account, :count).by(1)
      end

      it "creates an account with the provided name" do
        post user_registration_path, params: valid_params
        expect(Account.last.name).to eq("My Company")
      end

      it "generates a slug for the account" do
        post user_registration_path, params: valid_params
        expect(Account.last.slug).to eq("my-company")
      end

      it "associates the user with the account" do
        post user_registration_path, params: valid_params
        expect(User.last.account).to eq(Account.last)
      end

      it "redirects to the root path" do
        post user_registration_path, params: valid_params
        expect(response).to redirect_to(root_path)
      end
    end

    context "with invalid parameters" do
      it "does not create a user or account without an account name" do
        user_count = User.count
        account_count = Account.count

        post user_registration_path, params: {
          user: {
            account_name: "",
            email: "john@example.com",
            password: "password123",
            password_confirmation: "password123"
          }
        }

        expect(User.count).to eq(user_count)
        expect(Account.count).to eq(account_count)
      end

      it "does not create a user or account with mismatched passwords" do
        user_count = User.count
        account_count = Account.count

        post user_registration_path, params: {
          user: {
            account_name: "My Company",
            email: "john@example.com",
            password: "password123",
            password_confirmation: "different"
          }
        }

        expect(User.count).to eq(user_count)
        expect(Account.count).to eq(account_count)
      end

      it "does not create a user or account with an invalid email" do
        user_count = User.count
        account_count = Account.count

        post user_registration_path, params: {
          user: {
            account_name: "My Company",
            email: "invalid-email",
            password: "password123",
            password_confirmation: "password123"
          }
        }

        expect(User.count).to eq(user_count)
        expect(Account.count).to eq(account_count)
      end
    end
  end
end
