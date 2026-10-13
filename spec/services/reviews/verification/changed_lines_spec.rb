# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::ChangedLines do
  # @spec REVIEW-VERIFY-008
  describe ".from_files" do
    let(:two_hunk_patch) do
      <<~PATCH
        @@ -10,3 +10,7 @@ class User
         context
        -removed
        +added one
        +added two
        +added three
        +added four
        @@ -40,2 +44,2 @@ class User
         keep
        -old
        +new
      PATCH
    end

    let(:two_hunk_files) do
      [
        {
          filename: "app/models/user.rb",
          status: "modified",
          additions: 4,
          deletions: 1,
          patch: two_hunk_patch
        }
      ]
    end

    it "parses only changed right-side lines from unified diff patches" do
      changed_lines = described_class.from_files(two_hunk_files)

      expect(changed_lines.changed_file?("app/models/user.rb")).to be true
      expect(changed_lines.changed_file?("app/models/other.rb")).to be false
      # Only added right-side lines are valid anchors; unchanged hunk context
      # must not accept an inline review comment.
      added_lines = [ 11, 12, 13, 14, 45 ]
      expect(added_lines).to all(satisfy { |line| changed_lines.valid_line?("app/models/user.rb", line) })
      # Context line between hunks and unchanged hunk lines are not valid anchors.
      unchanged_lines = [ 10, 44, 16, 17, 9 ]
      expect(unchanged_lines).to all(satisfy { |line| !changed_lines.valid_line?("app/models/user.rb", line) })
      expect(changed_lines.valid_line?("app/models/other.rb", 10)).to be false
    end

    it "treats single-line hunks as valid anchors for that line" do
      files = [
        { filename: "a.txt", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n-old\n+new" }
      ]

      changed_lines = described_class.from_files(files)

      expect(changed_lines.valid_line?("a.txt", 1)).to be true
      expect(changed_lines.valid_line?("a.txt", 2)).to be false
    end

    it "treats an addition beginning with two plus signs as a changed line" do
      files = [
        { filename: "a.txt", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n-old\n+++counter" }
      ]

      changed_lines = described_class.from_files(files)

      expect(changed_lines.valid_line?("a.txt", 1)).to be true
    end

    it "exposes changed file names even without a parseable patch (binary files)" do
      files = [
        { filename: "image.png", status: "modified", additions: 0, deletions: 0, patch: nil }
      ]

      changed_lines = described_class.from_files(files)

      expect(changed_lines.changed_file_names).to eq([ "image.png" ])
      expect(changed_lines.changed_file?("image.png")).to be true
      expect(changed_lines.valid_line?("image.png", 1)).to be false
    end

    it "handles renamed files with no patch" do
      files = [
        { filename: "renamed.rb", status: "renamed", additions: 0, deletions: 0, patch: nil }
      ]

      changed_lines = described_class.from_files(files)

      expect(changed_lines.changed_file?("renamed.rb")).to be true
    end

    it "returns an empty index for an empty file set" do
      changed_lines = described_class.from_files([])

      expect(changed_lines).to be_empty
      expect(changed_lines.changed_file_names).to eq([])
    end
  end
end
