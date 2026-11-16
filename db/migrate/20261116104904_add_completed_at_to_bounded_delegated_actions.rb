# frozen_string_literal: true

# RDR-078 #4997: auditable lifecycle timestamp for the bounded authorization's
# exclusive-stop completion, mirroring revoked_at for revocation.
class AddCompletedAtToBoundedDelegatedActions < ActiveRecord::Migration[8.1]
  def change
    add_column :bounded_delegated_actions, :completed_at, :datetime
  end
end
