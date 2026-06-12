#!/usr/bin/ruby
# =============================================================================
# Unit tests for ConfirmateClient — no network required.
#
# post_evidence is stubbed per-test with canned Net::HTTPResponse instances, so
# these tests pin the RETRY/STATUS-HANDLING contract:
#   - success with empty / non-JSON / JSON body returns exactly once (no
#     re-POST of stored evidence)
#   - 409 (deterministic-UUID dedup) is success, not an error
#   - 4xx other than 401/409 fails fast without retries
#   - 5xx is retried up to MAX_RETRIES
# =============================================================================

require 'minitest/autorun'
require 'logger'

$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'confirmate_client'

class TestConfirmateClient < Minitest::Test
  EVIDENCE = { 'id' => 'test-ev', 'resource' => { 'virtualMachine' => { 'id' => 'one-vm-1' } } }.freeze

  def setup
    @config = {
      'confirmate' => { 'endpoint' => 'http://example.invalid:8080',
                        'auth' => { 'enabled' => false } },
      'logging' => { 'level' => 'error', 'file' => File::NULL }
    }
  end

  # Builds a client whose post_evidence returns the given responses in order
  # and counts how many POSTs were attempted.
  def client_with_responses(*responses)
    client = ConfirmateClient.new(@config, Logger.new(File::NULL))
    queue = responses
    client.define_singleton_method(:post_evidence) { |_ev| queue.shift }
    # avoid real sleeps between retries
    client.define_singleton_method(:sleep) { |_s| nil }
    [client, queue]
  end

  def http_response(klass, code, body)
    resp = klass.new('1.1', code.to_s, nil)
    resp.define_singleton_method(:body) { body }
    resp
  end

  def test_success_with_json_body_returns_parsed_once
    client, queue = client_with_responses(http_response(Net::HTTPOK, 200, '{"ok":true}'))
    assert_equal({ 'ok' => true }, client.store_evidence(EVIDENCE.dup))
    assert_empty queue, 'must not re-POST after success'
  end

  def test_success_with_empty_body_returns_once
    client, queue = client_with_responses(http_response(Net::HTTPOK, 200, ''))
    assert_equal({}, client.store_evidence(EVIDENCE.dup))
    assert_empty queue, 'empty success body must not fall through to retry'
  end

  def test_success_with_non_json_body_returns_once
    client, queue = client_with_responses(http_response(Net::HTTPOK, 200, 'stored!'))
    assert_equal({}, client.store_evidence(EVIDENCE.dup))
    assert_empty queue
  end

  def test_conflict_409_is_treated_as_already_stored
    client, queue = client_with_responses(http_response(Net::HTTPConflict, 409, 'duplicate'))
    assert_equal({}, client.store_evidence(EVIDENCE.dup))
    assert_empty queue, '409 dedup must not be retried'
  end

  def test_client_error_400_fails_fast_without_retry
    client, queue = client_with_responses(
      http_response(Net::HTTPBadRequest, 400, 'target of evaluation not found'),
      http_response(Net::HTTPOK, 200, '{}') # must never be consumed
    )
    err = assert_raises(RuntimeError) { client.store_evidence(EVIDENCE.dup) }
    assert_match(/HTTP 400/, err.message)
    assert_equal 1, queue.length, 'deterministic 4xx must not be retried'
  end

  def test_server_error_is_retried_then_succeeds
    client, queue = client_with_responses(
      http_response(Net::HTTPInternalServerError, 500, 'boom'),
      http_response(Net::HTTPOK, 200, '{}')
    )
    assert_equal({}, client.store_evidence(EVIDENCE.dup))
    assert_empty queue, '5xx then success: exactly two attempts'
  end

  def test_endpoint_trailing_slash_is_stripped
    cfg = { 'confirmate' => { 'endpoint' => 'https://host.example/' },
            'logging' => { 'level' => 'error', 'file' => File::NULL } }
    client = ConfirmateClient.new(cfg, Logger.new(File::NULL))
    assert_equal 'https://host.example', client.instance_variable_get(:@endpoint)
  end
end
