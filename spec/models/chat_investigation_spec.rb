# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigation do
  describe "author teardown" do
    it "destroys investigations before their authors during account teardown" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation)
      author = investigation.created_by

      expect { investigation.account.destroy! }
        .to change(described_class, :count).by(-1)
        .and change { User.where(id: author.id).count }.from(1).to(0)
    end

    it "restricts destroying a user who still authored investigations" do # @spec QUESTION-EXPLORATION-010
      investigation = create(:chat_investigation)

      expect { investigation.created_by.destroy! }
        .to raise_error(ActiveRecord::DeleteRestrictionError, /chat_investigations/)
    end
  end
end
