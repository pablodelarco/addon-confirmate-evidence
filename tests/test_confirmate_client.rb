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
  # --- mirroring to additional Targets of Evaluation ------------------------

  def mirror_config
    { 'confirmate' => { 'endpoint' => 'https://example.invalid', 'auth' => { 'enabled' => false } },
      'evidence' => { 'target_of_evaluation_id' => 'aaaaaaaa-0000-0000-0000-000000000001',
                      'additional_target_of_evaluation_ids' =>
                        ['bbbbbbbb-0000-0000-0000-000000000002',
                         'aaaaaaaa-0000-0000-0000-000000000001'] },
      'logging' => { 'file' => '/tmp/addon-mirror-test.log' } }
  end

  def sample_evidence
    { 'id' => '11111111-2222-3333-4444-555555555555',
      'timestamp' => '2026-08-28T00:00:00Z',
      'targetOfEvaluationId' => 'aaaaaaaa-0000-0000-0000-000000000001',
      'toolId' => 't',
      'resource' => { 'networkInterface' => { 'id' => 'one-nic-1-0', 'labels' => { 'ip' => '10.0.0.1' } } } }
  end

  def test_the_primary_target_is_never_mirrored_to_itself
    client = ConfirmateClient.new(mirror_config, Logger.new(IO::NULL))

    assert_equal ['bbbbbbbb-0000-0000-0000-000000000002'],
                 client.instance_variable_get(:@mirror_target_ids)
  end

  def test_no_additional_targets_means_no_mirroring
    config = mirror_config
    config['evidence'].delete('additional_target_of_evaluation_ids')
    client = ConfirmateClient.new(config, Logger.new(IO::NULL))

    assert_empty client.instance_variable_get(:@mirror_target_ids)
  end

  def test_mirrored_evidence_carries_the_new_target_and_a_distinct_id
    client = ConfirmateClient.new(mirror_config, Logger.new(IO::NULL))
    original = sample_evidence
    mirror = client.mirror_evidence(original, 'bbbbbbbb-0000-0000-0000-000000000002')

    assert_equal 'bbbbbbbb-0000-0000-0000-000000000002', mirror['targetOfEvaluationId']
    refute_equal original['id'], mirror['id']
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, mirror['id'])
  end

  def test_mirrored_evidence_id_is_deterministic
    client = ConfirmateClient.new(mirror_config, Logger.new(IO::NULL))
    target = 'bbbbbbbb-0000-0000-0000-000000000002'

    assert_equal client.mirror_evidence(sample_evidence, target)['id'],
                 client.mirror_evidence(sample_evidence, target)['id']
  end

  def test_mirroring_deep_copies_so_the_original_cannot_leak_into_it
    client = ConfirmateClient.new(mirror_config, Logger.new(IO::NULL))
    original = sample_evidence
    mirror = client.mirror_evidence(original, 'bbbbbbbb-0000-0000-0000-000000000002')
    original['resource']['networkInterface']['labels']['ip'] = 'mutated'

    assert_equal '10.0.0.1', mirror['resource']['networkInterface']['labels']['ip']
  end

end
