#!/usr/bin/ruby
# =============================================================================
# Unit tests for TokenManager
# =============================================================================

require 'minitest/autorun'
require 'logger'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'token_manager'

class TestTokenManager < Minitest::Test
  def setup
    @logger = Logger.new($stderr)
    @logger.level = Logger::ERROR # Quiet during tests
  end

  # --- Disabled mode ---

  def test_disabled_returns_nil_token
    # When confirmate.auth.enabled is false (or missing), no token is fetched
    # and the client must omit the Authorization header.
    config = { 'confirmate' => { 'auth' => { 'enabled' => false } } }
    tm = TokenManager.new(config, @logger)
    assert_nil tm.token
  end

  def test_disabled_by_default
    # No auth block at all -> disabled by default.
    config = { 'confirmate' => {} }
    tm = TokenManager.new(config, @logger)
    assert_nil tm.token
  end

  # --- Static token mode ---

  def test_static_token
    config = {
      'confirmate' => {
        'auth' => {
          'enabled' => true,
          'static_token' => 'test-static-token-12345'
        }
      }
    }
    tm = TokenManager.new(config, @logger)
    assert_equal 'test-static-token-12345', tm.token
  end

  def test_static_token_preferred_over_dynamic
    config = {
      'confirmate' => {
        'auth' => {
          'enabled' => true,
          'token_url' => 'http://localhost:8080/v1/auth/token',
          'client_id' => 'confirmate',
          'client_secret' => 'confirmate',
          'static_token' => 'static-wins'
        }
      }
    }
    tm = TokenManager.new(config, @logger)
    # Static token should be returned without any HTTP call
    assert_equal 'static-wins', tm.token
  end

  # --- Dynamic OAuth2 client_credentials mode ---

  def test_missing_credentials_raises
    config = {
      'confirmate' => {
        'auth' => { 'enabled' => true }
      }
    }
    tm = TokenManager.new(config, @logger)
    err = assert_raises(RuntimeError) { tm.token }
    assert_match(/missing auth configuration/, err.message)
  end

  def test_empty_static_token_triggers_dynamic
    # static_token = "" should not short-circuit; fall through to OAuth flow.
    # Using a deliberately unreachable port to assert the dynamic path runs.
    config = {
      'confirmate' => {
        'auth' => {
          'enabled' => true,
          'static_token' => '',
          'token_url' => 'http://127.0.0.1:1/v1/auth/token',
          'client_id' => 'confirmate',
          'client_secret' => 'confirmate'
        }
      }
    }
    tm = TokenManager.new(config, @logger)
    # StandardError (not RuntimeError) so we accept both our RuntimeError wrap
    # and the underlying Errno::ECONNREFUSED / SocketError / etc.
    assert_raises(StandardError) { tm.token }
  end
end
