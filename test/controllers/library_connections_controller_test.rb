# frozen_string_literal: true

require "test_helper"

class LibraryConnectionsControllerTest < ActionDispatch::IntegrationTest
  def build_connection(user)
    connection = LibraryConnection.create!(
      user: user,
      server_base_url: "https://host.example.com",
      remote_library_id: 99,
      grant_token: "secret-token",
      status: "active"
    )
    Library.create!(name: "Remote Library #{connection.id}", kind: "remote", library_connection: connection)
    connection
  end

  test "a user can disconnect their own remote library, removing the mirror" do
    user = users(:visitor1)
    connection = build_connection(user)
    library = connection.library
    login(user)

    assert_difference -> { LibraryConnection.count }, -1 do
      delete library_connection_path(connection)
    end

    assert_redirected_to libraries_path
    assert_nil Library.find_by(id: library.id)
  end

  test "a user cannot disconnect another user's connection" do
    connection = build_connection(users(:visitor2))
    login(users(:visitor1))

    assert_no_difference -> { LibraryConnection.count } do
      delete library_connection_path(connection)
    end

    assert_response :not_found
  end

  test "disconnect responds with no content for JSON clients" do
    user = users(:visitor1)
    connection = build_connection(user)
    login(user)

    delete library_connection_path(connection), as: :json

    assert_response :no_content
  end
end
