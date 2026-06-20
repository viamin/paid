# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::InstallationRepositories do
  let(:installation_id) { 42 }
  let(:app_id) { "123456" }
  let(:private_key) { OpenSSL::PKey::RSA.new(2048).to_pem }
  let(:fake_token) { "ghs_test_token_abc123" }

  around do |example|
    original_id = ENV.delete("PAID_AGENT_APP_ID")
    original_key = ENV.delete("PAID_AGENT_APP_PRIVATE_KEY")
    example.run
  ensure
    ENV["PAID_AGENT_APP_ID"] = original_id
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = original_key
  end

  before do
    ENV["PAID_AGENT_APP_ID"] = app_id
    ENV["PAID_AGENT_APP_PRIVATE_KEY"] = private_key
  end

  describe ".fetch" do
    before do
      stub_request(:post, "https://api.github.com/app/installations/#{installation_id}/access_tokens")
        .to_return(
          status: 201,
          body: { token: fake_token, expires_at: 1.hour.from_now.iso8601 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "paginates every installation repository page" do
      stub_repository_page(1, repositories: repositories_for_range(1..100), total_count: 102)
      stub_repository_page(2, repositories: repositories_for_range(101..102), total_count: 102)

      repositories = described_class.fetch(installation_id: installation_id)

      expect(repositories.size).to eq(102)
      expect(repositories.first).to include(first_serialized_repository)
      expect(repositories.last.fetch("full_name")).to eq("acme/repo-102")
    end

    it "raises a helpful error when GitHub rejects the request" do
      stub_request(:get, "https://api.github.com/installation/repositories")
        .with(query: { "per_page" => "100", "page" => "1" })
        .to_return(status: 403, body: { message: "Resource not accessible" }.to_json)

      expect {
        described_class.fetch(installation_id: installation_id)
      }.to raise_error(described_class::Error, /403.*Resource not accessible/)
    end

    it "wraps transport failures in the service error type" do
      stub_request(:get, "https://api.github.com/installation/repositories")
        .with(query: { "per_page" => "100", "page" => "1" })
        .to_timeout

      expect {
        described_class.fetch(installation_id: installation_id)
      }.to raise_error(described_class::Error, /request failed/)
    end
  end

  def repositories_for_range(range)
    range.map { |index| repository_payload(index, "acme/repo-#{index}") }
  end

  def stub_repository_page(page, repositories:, total_count:)
    stub_request(:get, "https://api.github.com/installation/repositories")
      .with(query: { "per_page" => "100", "page" => page.to_s })
      .to_return(
        status: 200,
        body: { total_count: total_count, repositories: repositories }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def first_serialized_repository
    {
      "id" => 1,
      "full_name" => "acme/repo-1",
      "name" => "repo-1",
      "owner" => "acme",
      "default_branch" => "main",
      "private" => false
    }
  end

  def repository_payload(id, full_name)
    owner, name = full_name.split("/", 2)

    {
      id: id,
      full_name: full_name,
      name: name,
      owner: { login: owner },
      default_branch: "main",
      private: false
    }
  end
end
