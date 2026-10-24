import Foundation

enum TerminalRuntimeCLI {
    static let script = #"""
RUNTIME_METADATA_MAX_BYTES = 16_384
RUNTIME_EVENT_RESPONSE_MAX_BYTES = 1_048_576
RUNTIME_CHECK_INTERVAL = 0.25
RUNTIME_DATE_KEYS = %w[updatedAt expiresAt occurredAt createdAt readAt resolvedAt]

def read_private_runtime_json(path, maximum)
  File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
    info = file.stat
    raise "Unsafe backend metadata or response." unless info.file? && info.uid == Process.uid && (info.mode & 0o077).zero? && info.size <= maximum
    data = file.read(maximum + 1)
    raise "Oversized backend response." if data.bytesize > maximum
    value = JSON.parse(data)
    raise "Invalid backend metadata or response." unless value.is_a?(Hash)
    value
  end
end

def backend_runtime_source(after = nil)
  path = File.join(ROOT, "runtime.json")
  metadata = read_private_runtime_json(path, RUNTIME_METADATA_MAX_BYTES)
  source = metadata["backend"]
  return nil unless source
  cursor = source.is_a?(Hash) && source["cursor"]
  raise "Invalid backend event source." unless source.is_a?(Hash) && source["schemaVersion"] == 1 &&
    source["root"].is_a?(String) && source["root"].start_with?("/") && cursor.is_a?(Hash) &&
    cursor["appEpoch"].is_a?(String) && cursor["sequence"].is_a?(Integer) && cursor["sequence"] >= 0
  explicit_agent_tab(cursor["appEpoch"])
  if after.is_a?(Hash) && after["appEpoch"].is_a?(String) && metadata["appEpoch"].is_a?(String) &&
      after["appEpoch"].casecmp?(metadata["appEpoch"]) && !after["appEpoch"].casecmp?(cursor["appEpoch"])
    return nil # An explicitly UI-scoped cursor retains the legacy UI route.
  end
  source
rescue Errno::ENOENT
  nil
rescue JSON::ParserError, SystemCallError, TypeError
  raise "Backend runtime metadata unavailable."
end

def validate_backend_event_root(root)
  raise "Invalid backend event endpoint." unless root.is_a?(String) && root.start_with?("/")
  [root, File.join(root, "requests"), File.join(root, "responses")].each do |path|
    info = File.lstat(path)
    raise "Unsafe backend event endpoint." unless info.directory? && !info.symlink? && info.uid == Process.uid && (info.mode & 0o077).zero?
  end
end

def normalize_runtime_dates(value)
  if value.is_a?(Hash)
    value.each do |key, item|
      if RUNTIME_DATE_KEYS.include?(key) && item.is_a?(Numeric)
        value[key] = Time.at(item + SWIFT_REFERENCE_EPOCH).utc.iso8601
      else
        normalize_runtime_dates(item)
      end
    end
  elsif value.is_a?(Array)
    value.each { |item| normalize_runtime_dates(item) }
  end
  value
end

def backend_wait_runtime_result(root, id, spec)
  path = File.join(root, "runtime.json")
  return nil unless File.exist?(path)
  metadata = read_private_runtime_json(path, RUNTIME_METADATA_MAX_BYTES)
  cursor = metadata["cursor"]
  raise "Invalid backend service metadata." unless metadata["schemaVersion"] == 1 && metadata["pid"].is_a?(Integer) &&
    metadata["pid"] > 0 && cursor.is_a?(Hash) && cursor["appEpoch"] == metadata["appEpoch"] && cursor["sequence"].is_a?(Integer)
  epoch = spec.dig("after", "appEpoch")
  outcome = "appRestarted" if epoch.is_a?(String) && !epoch.casecmp?(metadata["appEpoch"])
  unless outcome
    begin
      Process.kill(0, metadata["pid"])
    rescue Errno::ESRCH
      outcome = "appExited"
    rescue Errno::EPERM
      return nil
    end
  end
  return nil unless outcome
  {"ok" => true, "id" => id, "action" => "wait_session", "version" => metadata["version"],
    "waitResult" => {"waitID" => id, "outcome" => outcome, "cursor" => outcome == "appRestarted" ? cursor : spec.fetch("after")}}
end

def cancel_backend_wait(root, id)
  validate_backend_event_root(root)
  cancel_id = SecureRandom.uuid
  private_tool_request(File.join(root, "requests", "#{cancel_id}.json"),
    {"id" => cancel_id, "action" => "cancel_wait", "waitID" => id, "controlID" => CONTROL_ID, "noResponse" => true})
rescue StandardError
  warn "QTerm backend wait cancellation could not be delivered; its bounded timeout remains active."
end

def backend_endpoint_request(source, action, fields = {}, timeout_seconds: STATUS_RESPONSE_TIMEOUT, wait_spec: nil)
  received = false
  root = source.fetch("root")
  validate_backend_event_root(root)
  id = SecureRandom.uuid
  request_path = File.join(root, "requests", "#{id}.json")
  response_path = File.join(root, "responses", "#{id}.json")
  private_tool_request(request_path, {"id" => id, "action" => action}.merge(fields))
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  last_runtime_check = 0
  loop do
    if File.file?(response_path)
      response = read_private_runtime_json(response_path, RUNTIME_EVENT_RESPONSE_MAX_BYTES)
      raise "Invalid backend response identity." unless response["id"] == id && response["action"] == action
      received = true
      response["app"] = response.delete("appName") if response.key?("appName")
      response["tabID"] = fields["tab"] if fields["tab"]
      return normalize_runtime_dates(response)
    end
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise "Backend event endpoint timed out." if now >= deadline
    if wait_spec && now - last_runtime_check >= RUNTIME_CHECK_INTERVAL
      last_runtime_check = now
      runtime_result = backend_wait_runtime_result(root, id, wait_spec)
      if runtime_result
        received = true
        return runtime_result
      end
    end
    sleep STATUS_RESPONSE_POLL_INTERVAL
  end
rescue JSON::ParserError, SystemCallError, TypeError, KeyError
  raise "Backend event endpoint unavailable."
ensure
  cancel_backend_wait(root, id) if wait_spec && defined?(id) && id && !received
  FileUtils.rm_f(request_path) if defined?(request_path) && request_path
  FileUtils.rm_f(response_path) if defined?(response_path) && response_path
end
"""#
}
