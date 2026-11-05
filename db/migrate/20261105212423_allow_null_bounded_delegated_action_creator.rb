class AllowNullBoundedDelegatedActionCreator < ActiveRecord::Migration[8.1]
  def change
    change_column_null :bounded_delegated_actions, :created_by_id, true
  end
end
