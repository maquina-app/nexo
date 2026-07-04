# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class ToolsFetchTest < Minitest::Test
  def perms(mode: :auto, allow: %i[read glob fetch])
    Nexo::Permissions.new(mode: mode, allow: allow)
  end

  def tool(allow_hosts:, permissions: perms)
    Nexo::Tools::Fetch.new(sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: permissions, allow_hosts: allow_hosts)
  end

  def test_allowed_host_returns_body
    stub_request(:get, "https://news.example.com/latest").to_return(body: "HEADLINE")
    result = tool(allow_hosts: %w[news.example.com]).execute(url: "https://news.example.com/latest")
    assert_includes result[:body], "HEADLINE"
    refute result[:error]
  end

  def test_off_list_host_is_denied_and_makes_no_request
    result = tool(allow_hosts: %w[news.example.com]).execute(url: "https://evil.example.org/x")
    assert result[:error]
    assert_includes result[:error], "not in fetch allow-list"
    assert_not_requested :get, "https://evil.example.org/x"
  end

  def test_fetch_denied_under_read_only
    t = tool(allow_hosts: %w[news.example.com],
      permissions: perms(mode: :read_only, allow: %i[read glob]))
    result = t.execute(url: "https://news.example.com/latest")
    assert result[:error] # :fetch is default-denied like :shell
    assert_not_requested :get, "https://news.example.com/latest"
  end

  # Q4 suffix rule: a deeper subdomain is permitted by a parent allow-list entry.
  def test_subdomain_of_allowed_host_is_permitted
    stub_request(:get, "https://www.news.example.com/x").to_return(body: "OK")
    result = tool(allow_hosts: %w[news.example.com]).execute(url: "https://www.news.example.com/x")
    assert_includes result[:body], "OK"
  end

  # Q4 suffix rule: a look-alike host that merely contains the entry is refused,
  # and no HTTP request is made.
  def test_look_alike_host_is_refused_with_no_request
    result = tool(allow_hosts: %w[example.com]).execute(url: "https://notexample.com/x")
    assert result[:error]
    assert_not_requested :get, "https://notexample.com/x"
  end

  def test_non_http_scheme_is_refused
    result = tool(allow_hosts: %w[example.com]).execute(url: "file:///etc/passwd")
    assert result[:error]
    assert_includes result[:error], "http"
  end
end
