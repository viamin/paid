# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::CleanupPaidLabels do
  let(:project) { create(:project, label_integration_mode: "ignored") }

  describe ".preview" do
    it "lists only Paid catalog labels on open items" do # @spec LABEL-INTEGRATION-006
      issue = create(:issue, project:, labels: [ Issue::PAUSED_LABEL, "bug" ])
      create(:issue, :closed, project:, labels: [ Issue::PAUSED_LABEL ])

      result = described_class.preview(project:)

      expect(result.entries).to contain_exactly(have_attributes(issue_id: issue.id, labels: [ Issue::PAUSED_LABEL ]))
      expect(result.removed).to be_empty
    end

    it "rejects previews while Paid is still writing labels" do # @spec LABEL-INTEGRATION-006
      project.update!(label_integration_mode: "read_write")

      expect { described_class.preview(project:) }.to raise_error(ArgumentError, /read & write/)
    end
  end

  describe ".execute" do
    it "removes the previewed catalog labels and preserves user taxonomy" do # @spec LABEL-INTEGRATION-006 LABEL-INTEGRATION-007
      issue = create(:issue, project:, labels: [ Issue::PAUSED_LABEL, "bug" ])
      client = instance_double(GithubClient)
      allow(project).to receive(:label_cleanup_client).and_return(client)
      allow(client).to receive(:remove_labels_from_issue).and_return(removed: [ Issue::PAUSED_LABEL ], failed: [])

      result = described_class.execute(project:)

      expect(result.removed).to eq([ Issue::PAUSED_LABEL ])
      expect(issue.reload.labels).to eq([ "bug" ])
    end

    it "rejects cleanup while Paid is still writing labels" do # @spec LABEL-INTEGRATION-006
      project.update!(label_integration_mode: "read_write")

      expect { described_class.execute(project:) }.to raise_error(ArgumentError, /read & write/)
    end

    it "raises a GitHub client error when the project has no usable credential" do # @spec LABEL-INTEGRATION-006
      create(:issue, project:, labels: [ Issue::PAUSED_LABEL ])
      allow(project).to receive(:label_cleanup_client).and_return(nil)

      expect { described_class.execute(project:) }.to raise_error(GithubClient::Error, /no usable GitHub credential/)
    end

    it "raises a GitHub client error when the project's token was revoked after the project was created" do # @spec LABEL-INTEGRATION-006
      create(:issue, project:, labels: [ Issue::PAUSED_LABEL ])
      project.github_token.revoke!
      allow(project).to receive(:label_cleanup_client).and_return(nil)

      expect { described_class.execute(project:) }.to raise_error(GithubClient::Error, /no usable GitHub credential/)
    end
  end
end
