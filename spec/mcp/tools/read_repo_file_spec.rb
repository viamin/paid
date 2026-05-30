# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ReadRepoFile do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:contents)
  end

  describe "#call" do
    it "returns file contents" do
      file_data = Struct.new(:path, :type, :content, :size).new(
        "app/models/foo.rb", "file", Base64.strict_encode64("class Foo; end"), 16
      )
      allow(github_client).to receive(:contents).and_return(file_data)

      result = tool.call(project_id: project.id, path: "app/models/foo.rb")

      expect(result[:path]).to eq("app/models/foo.rb")
      expect(result[:content]).to eq("class Foo; end")
      expect(result[:identity]).to include("project-token")
    end

    it "returns error when path is a directory" do
      allow(github_client).to receive(:contents).and_return([])

      result = tool.call(project_id: project.id, path: "app/models")

      expect(result[:error]).to include("directory")
    end

    it "returns error for not-found path" do
      allow(github_client).to receive(:contents).and_raise(GithubClient::NotFoundError, "Not found")

      result = tool.call(project_id: project.id, path: "nonexistent.rb")

      expect(result[:error]).to include("not found")
    end

    it "returns error for binary file" do
      binary_content = "\xFF\x00\xFF\x00".b
      file_data = Struct.new(:path, :type, :content, :size).new(
        "image.png", "file", Base64.strict_encode64(binary_content), binary_content.bytesize
      )
      allow(github_client).to receive(:contents).and_return(file_data)

      result = tool.call(project_id: project.id, path: "image.png")

      expect(result[:error]).to include("binary")
    end

    it "returns error for NUL-containing content even when UTF-8 is otherwise valid" do
      binary_content = "\x00abc".b
      file_data = Struct.new(:path, :type, :content, :size).new(
        "tmp/data.bin", "file", Base64.strict_encode64(binary_content), binary_content.bytesize
      )
      allow(github_client).to receive(:contents).and_return(file_data)

      result = tool.call(project_id: project.id, path: "tmp/data.bin")

      expect(result[:error]).to include("binary")
    end

    it "returns error for oversized file" do
      big_content = "x" * (200 * 1024 + 1)
      file_data = Struct.new(:path, :type, :content, :size).new(
        "big_file.rb", "file", Base64.strict_encode64(big_content), big_content.bytesize
      )
      allow(github_client).to receive(:contents).and_return(file_data)

      result = tool.call(project_id: project.id, path: "big_file.rb")

      expect(result[:error]).to include("size limit")
    end

    it "checks API size before empty content and decoding" do
      file_data = Struct.new(:path, :type, :content, :size).new(
        "big_file.rb", "file", nil, 200 * 1024 + 1
      )
      allow(github_client).to receive(:contents).and_return(file_data)
      allow(Base64).to receive(:decode64).and_call_original

      result = tool.call(project_id: project.id, path: "big_file.rb")

      expect(result[:error]).to include("size limit")
      expect(Base64).not_to have_received(:decode64)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, path: "README.md") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "uses specified ref" do
      file_data = Struct.new(:path, :type, :content, :size).new(
        "README.md", "file", Base64.strict_encode64("# Hello"), 7
      )
      allow(github_client).to receive(:contents).and_return(file_data)

      tool.call(project_id: project.id, path: "README.md", ref: "develop")

      expect(github_client).to have_received(:contents).with(project.full_name, hash_including(ref: "develop"))
    end
  end
end
