require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

module UI
  def self.user_error!(message)
    raise message
  end
end

def lane(name, &block)
  $native_lanes ||= {}
  $native_lanes[name] = block
end

%i[create_keychain delete_keychain app_store_connect_api_key update_code_signing_settings build_app upload_to_testflight upload_to_play_store].each do |action|
  define_method(action) do |options|
    $native_calls << [action, options]
    action == :app_store_connect_api_key ? { token: 'test-only' } : nil
  end
end

def match(options)
  $native_calls << [:match, options]
  raise 'Missing signing profile' if $native_fail_match
end

load File.join(__dir__, 'Fastfile')

class NativeLanesTest < Minitest::Test
  def setup
    $native_calls = []
    $native_fail_match = false
    @root = Dir.mktmpdir('mainpath-native-lanes-')
    @old_env = ENV.to_h
    ENV.update('MAINPATH_PROJECT_ROOT' => @root, 'GITHUB_RUN_ID' => '42',
               'GITHUB_RUN_ATTEMPT' => '1', 'IOS_APP_IDENTIFIER' => 'org.acme.app',
               'ANDROID_APP_IDENTIFIER' => 'org.acme.app',
               'APP_STORE_CONNECT_KEY' => '-----BEGIN PRIVATE KEY-----test-only',
               'APP_STORE_CONNECT_KEY_ID' => 'test-key',
               'APP_STORE_CONNECT_KEY_ISSUER_ID' => 'test-issuer',
               'APP_STORE_CONNECT_DEVELOPER_TEAM_ID' => 'test-team',
               'MATCH_GIT_URL' => 'https://example.invalid/own-org/match.git',
               'MATCH_GIT_BASIC_AUTHORIZATION' => 'test-only',
               'sigh_org.acme.app_appstore_profile-name' => 'match AppStore org.acme.app',
               'PLAY_STORE_CREDENTIALS_BASE64' => Base64.strict_encode64('{"type":"service_account"}'))
  end

  def teardown
    ENV.replace(@old_env)
    FileUtils.remove_entry(@root)
  end

  def test_signed_build_uses_readonly_team_signing_and_always_cleans_keychain
    FileUtils.mkdir_p(File.join(@root, 'ios', 'Example.xcworkspace'))
    FileUtils.mkdir_p(File.join(@root, 'ios', 'Example.xcodeproj'))
    $native_lanes.fetch(:build_ios_release).call
    signing = $native_calls.find { |action, _| action == :match }.last
    assert_equal true, signing[:readonly]
    assert_equal 'test-team', signing[:team_id]
    assert_equal 'test-team', signing[:git_branch]
    assert_equal 'org.acme.app', signing[:app_identifier]
    build = $native_calls.find { |action, _| action == :build_app }.last
    assert_equal 'Release', build[:configuration]
    assert_equal 'app-store', build[:export_method]
    assert_equal :delete_keychain, $native_calls.last.first
    refute $native_calls.any? { |action, _| action.to_s.start_with?('upload_') }
  end

  def test_missing_profile_stops_build_and_explains_how_to_prepare_signing
    $native_fail_match = true
    error = assert_raises(RuntimeError) { $native_lanes.fetch(:build_ios_release).call }
    assert_match(/Prepare the selected Apple team certificate/, error.message)
    assert_equal :delete_keychain, $native_calls.last.first
    refute $native_calls.any? { |action, _| action == :build_app }
  end

  def test_beta_lanes_stay_in_internal_channels_and_do_not_change_listings
    FileUtils.mkdir_p(File.join(@root, 'native-artifacts'))
    File.write(File.join(@root, 'native-artifacts', 'App.ipa'), 'test-only')
    File.write(File.join(@root, 'native-artifacts', 'app.aab'), 'test-only')
    $native_lanes.fetch(:internal_testflight).call
    $native_lanes.fetch(:internal_play).call
    ios = $native_calls.find { |action, _| action == :upload_to_testflight }.last
    assert_equal false, ios[:skip_waiting_for_build_processing]
    assert_equal true, ios[:skip_submission]
    assert_equal false, ios[:distribute_external]
    assert_equal false, ios[:notify_external_testers]
    android = $native_calls.find { |action, _| action == :upload_to_play_store }.last
    assert_equal 'internal', android[:track]
    assert_equal true, android[:skip_upload_metadata]
    assert_equal true, android[:skip_upload_images]
    assert_equal true, android[:skip_upload_screenshots]
  end

  def test_ambiguous_artifacts_cannot_publish_an_unrelated_build
    FileUtils.mkdir_p(File.join(@root, 'native-artifacts'))
    %w[first.ipa second.ipa].each { |name| File.write(File.join(@root, 'native-artifacts', name), 'test-only') }
    assert_raises(RuntimeError) { $native_lanes.fetch(:internal_testflight).call }
    refute $native_calls.any? { |action, _| action == :upload_to_testflight }
  end
end
