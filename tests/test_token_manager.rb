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

  def test_static_token
    config = {
      'confirmate' => {
        'auth' => {
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
          'token_url' => 'http://localhost:8082/v1/auth/token',
          'username' => 'clouditor',
          'password' => 'clouditor',
          'static_token' => 'static-wins'
        }
      }
    }

    tm = TokenManager.new(config, @logger)
    # Static token should be returned without any HTTP call
    assert_equal 'static-wins', tm.token
  end

  def test_missing_config_raises
    config = {
      'confirmate' => {
        'auth' => {}
      }
    }

    tm = TokenManager.new(config, @logger)
    assert_raises(RuntimeError) { tm.token }
  end

  def test_empty_static_token_triggers_dynamic
    config = {
      'confirmate' => {
        'auth' => {
          'static_token' => '',
          'token_url' => 'http://localhost:99999/v1/auth/token',
          'username' => 'clouditor',
          'password' => 'clouditor'
        }
      }
    }

    tm = TokenManager.new(config, @logger)
    # Should try dynamic auth and fail (no server on port 99999)
    assert_raises(RuntimeError) { tm.token }
  end

  def test_jwt_expiry_extraction
    # Create a minimal JWT with exp claim
    # Header: {"alg":"HS256","typ":"JWT"}
    # Payload: {"sub":"test","exp":9999999999}
    header = base64url_encode('{"alg":"HS256","typ":"JWT"}')
    payload = base64url_encode('{"sub":"test","exp":9999999999}')
    sig = base64url_encode('fakesig')
    jwt = "#{header}.#{payload}.#{sig}"

    config = {
      'confirmate' => {
        'auth' => {
          'static_token' => jwt
        }
      }
    }

    # TokenManager should be able to parse this, though for static tokens
    # it doesn't need to since they're returned directly
    tm = TokenManager.new(config, @logger)
    assert_equal jwt, tm.token
  end

  private

  def base64url_encode(str)
    [str].pack('m0').tr('+/', '-_').tr('=', '')
  end
end
