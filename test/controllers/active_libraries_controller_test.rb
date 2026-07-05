# frozen_string_literal: true

require "test_helper"

class ActiveLibrariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:visitor1)
    @owned = libraries(:default_library) # owner: visitor1
    @second = Library.create!(
      name: "Second Owned Library",
      kind: "local",
      media_path: Rails.root.join("test", "fixtures", "files").to_s,
      owner: @user
    )
    @foreign = libraries(:secondary_library)
    @foreign.update!(owner: users(:visitor2))
  end

  test "switches the active library to an authorized library (Req 3.1)" do
    login(@user)

    patch active_library_path, params: { library_id: @second.id }

    assert_redirected_to library_overview_path
    assert_equal @second.id, @user.reload.active_library_id
  end

  test "rejects switching to an unauthorized library and leaves the selection unchanged (Req 3.6)" do
    login(@user)
    @user.update!(active_library: @owned)

    patch active_library_path, params: { library_id: @foreign.id }

    assert_response :forbidden
    assert_equal @owned.id, @user.reload.active_library_id
  end
end
