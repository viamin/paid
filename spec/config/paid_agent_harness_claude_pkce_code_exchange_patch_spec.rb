# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidAgentHarnessClaudePkceCodeExchangePatch do
  describe ".generate_pkce_challenge" do
    it "returns a hash with code_verifier and code_challenge" do
      result = AgentHarness::Authentication.generate_pkce_challenge

      expect(result).to include(:code_verifier, :code_challenge)
      expect(result[:code_verifier]).to be_a(String)
      expect(result[:code_challenge]).to be_a(String)
    end

    it "generates URL-safe base64 values" do
      result = AgentHarness::Authentication.generate_pkce_challenge

      expect(result[:code_verifier]).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(result[:code_challenge]).to match(/\A[A-Za-z0-9_-]+\z/)
    end

    it "produces a code_challenge that is the S256 hash of the verifier" do
      result = AgentHarness::Authentication.generate_pkce_challenge

      expected_challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(result[:code_verifier]),
        padding: false
      )
      expect(result[:code_challenge]).to eq(expected_challenge)
    end

    it "generates unique verifiers on each call" do
      results = Array.new(5) { AgentHarness::Authentication.generate_pkce_challenge }
      verifiers = results.map { |r| r[:code_verifier] }

      expect(verifiers.uniq.size).to eq(5)
    end
  end

  describe ".auth_url_with_pkce" do
    it "returns a hash with url, code_verifier, code_challenge, and state" do
      result = AgentHarness::Authentication.auth_url_with_pkce(:claude)

      expect(result).to include(:url, :code_verifier, :code_challenge, :state)
    end

    it "builds a URL based on the auth_url for the provider" do
      result = AgentHarness::Authentication.auth_url_with_pkce(:claude)

      expect(result[:url]).to start_with("https://claude.ai/oauth/authorize?")
    end

    it "includes required PKCE query parameters" do
      result = AgentHarness::Authentication.auth_url_with_pkce(:claude)
      uri = URI.parse(result[:url])
      params = URI.decode_www_form(uri.query).to_h

      expect(params["response_type"]).to eq("code")
      expect(params["code_challenge"]).to eq(result[:code_challenge])
      expect(params["code_challenge_method"]).to eq("S256")
      expect(params["state"]).to eq(result[:state])
    end

    it "uses default redirect_uri and scope" do
      result = AgentHarness::Authentication.auth_url_with_pkce(:claude)
      uri = URI.parse(result[:url])
      params = URI.decode_www_form(uri.query).to_h

      expect(params["redirect_uri"]).to eq("urn:ietf:wg:oauth:2.0:oob")
      expect(params["scope"]).to eq("user:inference")
    end

    it "accepts custom redirect_uri and scope" do
      result = AgentHarness::Authentication.auth_url_with_pkce(
        :claude,
        redirect_uri: "http://localhost:3000/callback",
        scope: "user:read user:write"
      )
      uri = URI.parse(result[:url])
      params = URI.decode_www_form(uri.query).to_h

      expect(params["redirect_uri"]).to eq("http://localhost:3000/callback")
      expect(params["scope"]).to eq("user:read user:write")
    end

    it "works with the :anthropic alias" do
      result = AgentHarness::Authentication.auth_url_with_pkce(:anthropic)

      expect(result[:url]).to start_with("https://claude.ai/oauth/authorize?")
    end

    it "raises UnsupportedAuthFlowError for unsupported providers" do
      expect {
        AgentHarness::Authentication.auth_url_with_pkce(:codex)
      }.to raise_error(AgentHarness::UnsupportedAuthFlowError)
    end
  end

  describe ".exchange_code" do
    let(:token_response_body) do
      {
        "access_token" => "sk-ant-oat01-test-token",
        "refresh_token" => "sk-ant-ort01-test-refresh",
        "token_type" => "Bearer",
        "expires_in" => 86400,
        "scope" => "user:inference"
      }
    end

    context "with a successful exchange" do
      before do
        stub_request(:post, "https://claude.ai/oauth/token")
          .with(
            headers: {
              "Content-Type" => "application/x-www-form-urlencoded",
              "Accept" => "application/json"
            }
          )
          .to_return(
            status: 200,
            body: token_response_body.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns the parsed token response" do
        result = AgentHarness::Authentication.exchange_code(
          :claude,
          code: "auth-code-123",
          code_verifier: "verifier-abc"
        )

        expect(result).to eq(token_response_body)
      end

      it "sends the correct form parameters" do
        AgentHarness::Authentication.exchange_code(
          :claude,
          code: "auth-code-123",
          code_verifier: "verifier-abc"
        )

        expect(WebMock).to have_requested(:post, "https://claude.ai/oauth/token")
          .with(body: hash_including(
            "grant_type" => "authorization_code",
            "code" => "auth-code-123",
            "code_verifier" => "verifier-abc",
            "redirect_uri" => "urn:ietf:wg:oauth:2.0:oob"
          ))
      end

      it "accepts a custom redirect_uri" do
        AgentHarness::Authentication.exchange_code(
          :claude,
          code: "auth-code-123",
          code_verifier: "verifier-abc",
          redirect_uri: "http://localhost:3000/callback"
        )

        expect(WebMock).to have_requested(:post, "https://claude.ai/oauth/token")
          .with(body: hash_including("redirect_uri" => "http://localhost:3000/callback"))
      end

      it "strips whitespace from the authorization code" do
        AgentHarness::Authentication.exchange_code(
          :claude,
          code: "  auth-code-123  ",
          code_verifier: "verifier-abc"
        )

        expect(WebMock).to have_requested(:post, "https://claude.ai/oauth/token")
          .with(body: hash_including("code" => "auth-code-123"))
      end

      it "works with the :anthropic alias" do
        result = AgentHarness::Authentication.exchange_code(
          :anthropic,
          code: "auth-code-123",
          code_verifier: "verifier-abc"
        )

        expect(result["access_token"]).to eq("sk-ant-oat01-test-token")
      end
    end

    context "with an error response" do
      it "raises AuthenticationError on 400 (invalid_grant)" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_return(
            status: 400,
            body: { error: "invalid_grant", error_description: "Authorization code expired" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "expired-code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::AuthenticationError, /Authorization code expired/)
      end

      it "raises AuthenticationError on 401" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_return(
            status: 401,
            body: { error: "invalid_client" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::AuthenticationError, /invalid_client/)
      end

      it "includes error context in the exception" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_return(
            status: 400,
            body: { error: "invalid_grant", error_description: "Code verifier mismatch" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "wrong-verifier")
        }.to raise_error(AgentHarness::AuthenticationError) do |e|
          expect(e.context[:status]).to eq(400)
          expect(e.context[:error]).to eq("invalid_grant")
          expect(e.context[:error_description]).to eq("Code verifier mismatch")
          expect(e.provider).to eq(:claude)
        end
      end

      it "raises AuthenticationError on unparseable JSON response" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_return(status: 200, body: "not json")

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::AuthenticationError, /Invalid JSON/)
      end
    end

    context "with network errors" do
      it "raises AuthenticationError on connection refused" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_raise(Errno::ECONNREFUSED.new("Connection refused"))

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::AuthenticationError, /Failed to connect/)
      end

      it "raises AuthenticationError on timeout" do
        stub_request(:post, "https://claude.ai/oauth/token")
          .to_raise(Net::OpenTimeout.new("execution expired"))

        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::AuthenticationError, /Failed to connect/)
      end
    end

    context "with invalid parameters" do
      it "raises ArgumentError for blank code" do
        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "", code_verifier: "verifier")
        }.to raise_error(ArgumentError, /code must be a non-empty string/)
      end

      it "raises ArgumentError for nil code" do
        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: nil, code_verifier: "verifier")
        }.to raise_error(ArgumentError, /code must be a non-empty string/)
      end

      it "raises ArgumentError for blank code_verifier" do
        expect {
          AgentHarness::Authentication.exchange_code(:claude, code: "code", code_verifier: "")
        }.to raise_error(ArgumentError, /code_verifier must be a non-empty string/)
      end

      it "raises UnsupportedAuthFlowError for unsupported providers" do
        expect {
          AgentHarness::Authentication.exchange_code(:codex, code: "code", code_verifier: "verifier")
        }.to raise_error(AgentHarness::UnsupportedAuthFlowError)
      end
    end
  end
end
