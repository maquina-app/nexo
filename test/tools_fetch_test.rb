# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "resolv"

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

  # An allow-listed host that resolves to a private/loopback/metadata address is
  # still refused, even though the allow-list passed — the address guard uses the
  # SAME resolution the connection is pinned to (no DNS-rebinding window).
  def test_allowed_host_resolving_to_private_ip_is_refused
    t = tool(allow_hosts: %w[internal.example.com])
    Resolv.stub(:getaddresses, ["10.0.0.5"]) do
      result = t.execute(url: "https://internal.example.com/x")
      assert result[:error]
      assert_includes result[:error], "private/loopback"
    end
    assert_not_requested :get, "https://internal.example.com/x"
  end

  # The cloud metadata address (link-local) and 0.0.0.0 (a stdlib-predicate gap)
  # are both refused.
  def test_metadata_and_zero_addresses_are_refused
    t = tool(allow_hosts: %w[metadata.example.com])
    ["169.254.169.254", "0.0.0.0"].each do |ip|
      Resolv.stub(:getaddresses, [ip]) do
        result = t.execute(url: "https://metadata.example.com/latest/meta-data/")
        assert result[:error], "expected #{ip} to be refused"
        assert_includes result[:error], "private/loopback"
      end
    end
  end
end
