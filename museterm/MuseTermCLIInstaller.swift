import Foundation

enum MuseTermCLIInstaller {
    static let installDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)
    static let installURL = installDirectory.appendingPathComponent("qterm")

    static var installPath: String {
        installURL.path
    }

    static var supportPath: String {
        TerminalToolPaths.rootDirectory.path
    }

    static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: installURL.path)
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try script.write(to: installURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
    }

    static let script = #"""
#!/usr/bin/env ruby
# QTerm CLI and MCP bridge.
# Installed by QTerm. Safe to replace on app updates.

require "json"
require "securerandom"
require "fileutils"
require "time"
require "shellwords"
require "timeout"
require "open3"

# MCP hosts spawn us with a bare environment, so LANG is often unset and Ruby falls back to
# US-ASCII. Any non-ASCII tab title or path then raises before we get a chance to answer.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil
STDIN.set_encoding(Encoding::UTF_8)
STDOUT.set_encoding(Encoding::UTF_8)
ARGV.map! { |arg| arg.dup.force_encoding(Encoding::UTF_8) }

ROOT = File.expand_path("~/Library/Application Support/QTerm/Tools")
STATE = File.join(ROOT, "state.json")
REQUESTS = File.join(ROOT, "requests")
RESPONSES = File.join(ROOT, "responses")
CLIENT_ID = "qterm-cli"
CONTROL_ID = SecureRandom.uuid
CONTROLLED_TABS = {}
MCP_WRITE_LOCK = Mutex.new
KEYCHAIN_SERVICE = "im.some.museterm.tool-access"

def ensure_dirs
  FileUtils.mkdir_p(REQUESTS)
  FileUtils.mkdir_p(RESPONSES)
  FileUtils.chmod(0o700, [ROOT, REQUESTS, RESPONSES])
end

def access_token
  output, _error, status = Open3.capture3(
    "security", "find-generic-password",
    "-s", KEYCHAIN_SERVICE,
    "-a", CLIENT_ID,
    "-w"
  )
  status.success? ? output.strip : nil
end

def read_state
  raise "QTerm is not publishing tool state yet. Open QTerm first." unless File.file?(STATE)
  JSON.parse(File.read(STATE))
end

def selected_tab(state, selector)
  tabs = state.fetch("tabs", [])
  selector = "selected" if selector.nil? || selector.empty?
  return tabs.find { |tab| tab["isSelected"] } || tabs.first if selector == "selected"

  if selector =~ /\A\d+\z/
    index = selector.to_i
    return tabs.find { |tab| tab["index"] == index }
  end

  tabs.find { |tab|
    tab["id"] == selector ||
      tab["id"].start_with?(selector) ||
      tab["title"] == selector
  }
end

def tail_chars(value, count)
  text = value.to_s
  return text if count.nil?
  limit = count.to_i
  return "" if limit <= 0
  chars = text.each_char.to_a
  chars.last(limit).join
end

def parse_common(args)
  tab = nil
  chars = nil
  json = false
  timeout = nil
  query = nil
  rest = []
  until args.empty?
    item = args.shift
    case item
    when "--tab", "-t"
      tab = args.shift
    when "--chars", "-c"
      chars = args.shift
    when "--query", "-q"
      query = args.shift
    when "--timeout"
      timeout = args.shift
    when "--json"
      json = true
    else
      rest << item
    end
  end
  [tab, chars, json, rest, timeout, query]
end

def print_json(value)
  puts JSON.pretty_generate(value)
end

def text_payload(state, tab, field, chars)
  text = tab[field].to_s
  limit = chars.nil? ? nil : chars.to_i
  returned = tail_chars(text, chars)
  {
    "schemaVersion" => state["schemaVersion"],
    "app" => state["app"],
    "version" => state["version"],
    "snapshotSequence" => state["snapshotSequence"],
    "tabID" => tab["id"],
    "shellName" => tab["shellName"],
    "currentDirectory" => tab["currentDirectory"],
    "selectedTabID" => state["selectedTabID"],
    "field" => field,
    "text" => returned,
    "textCharacters" => text.length,
    "returnedCharacters" => returned.length,
    "limit" => limit,
    "truncated" => limit ? text.length > limit : false
  }
end

def tab_summary_keys
  ["id", "index", "title", "subtitle", "currentDirectory", "shellName", "sessionTunnelStatus", "aiControlled", "aiLeaseExpiresAt", "aiRequiresTakeover", "agent", "runtime", "isSelected", "state", "columns", "rows", "updatedAt"]
end

def tab_summaries(state)
  state.fetch("tabs", []).map { |tab|
    tab.slice(*tab_summary_keys)
  }
end

def tabs_payload(state)
  {
    "schemaVersion" => state["schemaVersion"],
    "app" => state["app"],
    "version" => state["version"],
    "snapshotSequence" => state["snapshotSequence"],
    "selectedTabID" => state["selectedTabID"],
    "eventCursor" => state["eventCursor"],
    "sessions" => state["sessions"],
    "tabs" => tab_summaries(state)
  }
end

def session_tunnels_payload(state)
  tunnels = state.fetch("tabs", []).each_with_object([]) { |tab, out|
    tunnel = tab["sessionTunnelStatus"]
    next unless tunnel
    out << tunnel.merge(
      "tabID" => tab["id"],
      "tabIndex" => tab["index"],
      "tabTitle" => tab["title"],
      "tabShellName" => tab["shellName"]
    )
  }
  {
    "schemaVersion" => state["schemaVersion"],
    "app" => state["app"],
    "version" => state["version"],
    "snapshotSequence" => state["snapshotSequence"],
    "selectedTabID" => state["selectedTabID"],
    "sessionTunnels" => tunnels
  }
end

def send_request(action:, tab: nil, text: nil, key: nil, bytes: nil, directory: nil, profile: nil, shortcut: nil, tunnel_name: nil, target_host: nil, target_port: nil, local_port: nil, timeout_seconds: 3.0, agent_kind: nil, agent_report: nil, event_cursor: nil, event_limit: nil, wait_spec: nil, attention_id: nil, attention_version: nil, project_request: nil)
  received = false
  timeout_seconds = timeout_seconds.to_f
  raise "timeout must be positive." if timeout_seconds <= 0

  ensure_dirs
  id = SecureRandom.uuid
  request = {
    "id" => id,
    "action" => action,
    "tab" => tab,
    "text" => text,
    "key" => key,
    "bytes" => bytes,
    "directory" => directory,
    "profile" => profile,
    "shortcut" => shortcut,
    "tunnelName" => tunnel_name,
    "targetHost" => target_host,
    "targetPort" => target_port,
    "localPort" => local_port,
    "clientID" => CLIENT_ID,
    "controlID" => CONTROL_ID,
    "authToken" => (["report_agent_state", "wait_session", "list_attention"].include?(action) || (action == "project_layout" && project_request && project_request["operation"] == "list") ? nil : access_token),
    "projectRequest" => project_request,
    "waitSpec" => wait_spec, "attentionID" => attention_id, "attentionVersion" => attention_version,
    "agentKind" => agent_kind, "agentReport" => agent_report,
    "eventCursor" => event_cursor, "eventLimit" => event_limit
  }.compact
  request_path = File.join(REQUESTS, "#{id}.json")
  private_tool_request(request_path, request)
  response_path = File.join(RESPONSES, "#{id}.json")
  last_runtime_check = 0

  Timeout.timeout(timeout_seconds) do
    loop do
      if File.file?(response_path)
        response = JSON.parse(File.read(response_path))
        FileUtils.rm_f(response_path)
        received = true
        return response
      end
      if action == "wait_session" && Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_runtime_check >= 0.25
        last_runtime_check = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        runtime_result = wait_runtime_result(id, wait_spec)
        if runtime_result
          received = true
          FileUtils.rm_f(request_path)
          FileUtils.rm_f(response_path)
          return runtime_result
        end
      end
      sleep 0.05
    end
  end
rescue Timeout::Error
  raise "QTerm did not answer the tool request in time."
ensure
  if action == "project_layout" && !received
    FileUtils.rm_f(request_path) if request_path
    FileUtils.rm_f(response_path) if response_path
  end
  if action == "wait_session" && id && !received
    abandon_wait(id)
    FileUtils.rm_f(request_path) if request_path
    FileUtils.rm_f(response_path) if response_path
  end
end

def require_tab(state, selector)
  tab = selected_tab(state, selector)
  raise "No QTerm tab matched #{selector.inspect}." unless tab
  tab
end

def command_tabs(args)
  state = read_state
  print_json(tabs_payload(state))
end

def command_screen(args)
  tab_selector, chars, json, _rest = parse_common(args)
  state = read_state
  tab = require_tab(state, tab_selector)
  if json
    print_json(text_payload(state, tab, "screen", chars))
  else
    puts tail_chars(tab["screen"], chars)
  end
end

def command_history(args)
  tab_selector, chars, json, _rest = parse_common(args)
  state = read_state
  tab = require_tab(state, tab_selector)
  if json
    print_json(text_payload(state, tab, "history", chars))
  else
    puts tail_chars(tab["history"], chars)
  end
end

def command_commands(args)
  tab_selector, chars, _json, _rest, _timeout, query = parse_common(args)
  state = read_state
  tab = require_tab(state, tab_selector)
  print_json(commands_payload(state, tab, chars, query))
end

def normalize_query_value(value)
  value.to_s.downcase.tr("-", "_")
end

def normalize_query_field(key, value)
  normalized = normalize_query_value(value)
  return nil if normalized.empty?

  case key
  when "risk", "risk_level"
    case normalized
    when "read_only", "readonly", "read" then ["risk", "read_only"]
    when "mutating", "mutation", "write" then ["risk", "mutating"]
    when "dangerous", "danger", "destructive" then ["risk", "dangerous"]
    when "unknown", "unclear" then ["risk", "unknown"]
    end
  when "state", "lifecycle", "lifecycle_state"
    case normalized
    when "running" then ["lifecycle", "running"]
    when "succeeded", "success", "ok" then ["lifecycle", "succeeded"]
    when "failed", "failure", "error" then ["lifecycle", "failed"]
    when "interrupted", "interrupt" then ["lifecycle", "interrupted"]
    when "superseded" then ["lifecycle", "superseded"]
    when "completed_unknown_status", "unknown" then ["lifecycle", "completed_unknown_status"]
    end
  when "boundary", "boundary_confidence"
    case normalized
    when "high" then ["boundary", "high"]
    when "medium", "med" then ["boundary", "medium"]
    when "low" then ["boundary", "low"]
    end
  end
end

def parse_command_query(query)
  filters = { "risk" => [], "lifecycle" => [], "boundary" => [], "text" => [] }
  query.to_s.split(/\s+/).each do |token|
    next if token.empty?
    key, raw_value = token.split(":", 2)
    if raw_value && !raw_value.empty?
      normalized = normalize_query_field(key.downcase, raw_value)
      if normalized
        filters[normalized[0]] << normalized[1]
        next
      end
    end
    filters["text"] << token
  end
  filters
end

def command_block_searchable_text(block)
  [
    block["command"],
    block["workingDirectory"],
    block["outputTail"],
    block["outputSummary"],
    block["statusText"],
    block["commandLifecycleState"],
    block["commandRiskLevel"],
    Array(block["commandRiskReasons"]).join(" "),
    block["commandStartSource"],
    block["completionSource"],
    block["commandBoundaryConfidence"],
    Array(block["commandBoundaryReasons"]).join(" ")
  ].compact.join("\n").downcase
end

def command_block_matches_query?(block, filters)
  unless filters["risk"].empty?
    return false unless filters["risk"].include?(block["commandRiskLevel"].to_s)
  end
  unless filters["lifecycle"].empty?
    return false unless filters["lifecycle"].include?(block["commandLifecycleState"].to_s)
  end
  unless filters["boundary"].empty?
    return false unless filters["boundary"].include?(block["commandBoundaryConfidence"].to_s)
  end
  return true if filters["text"].empty?

  searchable = command_block_searchable_text(block)
  filters["text"].all? { |term| searchable.include?(term.downcase) }
end

def filter_command_blocks(blocks, filters)
  return blocks if filters.nil?
  blocks.select { |block| command_block_matches_query?(block, filters) }
end

def command_query_filters(query)
  return nil if query.nil? || query.to_s.strip.empty?
  parse_command_query(query)
end

def commands_payload(state, tab, chars, query = nil)
  source_blocks = tab.fetch("commandBlocks", [])
  query_filters = command_query_filters(query)
  filtered_blocks = filter_command_blocks(source_blocks, query_filters)
  output_tail_limit = chars.nil? ? nil : chars.to_i
  blocks = filtered_blocks.map { |block|
    copy = block.dup
    output_tail = copy["outputTail"].to_s
    output_character_count = copy.key?("outputCharacterCount") ? copy["outputCharacterCount"].to_i : output_tail.length
    returned_tail = tail_chars(output_tail, chars)
    copy["outputTailCharacters"] = output_tail.length
    copy["outputTailReturnedCharacters"] = returned_tail.length
    copy["outputTailLimit"] = output_tail_limit
    copy["outputTailTruncated"] = output_tail_limit ? output_tail.length > output_tail_limit : false
    copy["outputTailStoredTruncated"] = output_character_count > output_tail.length
    copy["outputTail"] = returned_tail
    copy
  }
  {
    "schemaVersion" => state["schemaVersion"],
    "app" => state["app"],
    "version" => state["version"],
    "snapshotSequence" => state["snapshotSequence"],
    "tabID" => tab["id"],
    "shellName" => tab["shellName"],
    "currentDirectory" => tab["currentDirectory"],
    "selectedTabID" => state["selectedTabID"],
    "commandCount" => source_blocks.length,
    "filteredCommandCount" => filtered_blocks.length,
    "returnedCommandCount" => blocks.length,
    "commandQuery" => (query.nil? || query.to_s.strip.empty? ? nil : query.to_s),
    "commandQueryFilters" => query_filters,
    "outputTailLimit" => output_tail_limit,
    "diagnostics" => tab.fetch("commandDiagnostics", {}),
    "commands" => blocks
  }
end

def command_input(args)
  tab_selector, _chars, json, rest, timeout = parse_common(args)
  text = rest.join(" ")
  raise "input requires text." if text.empty?
  response = send_request(action: "input", tab: tab_selector, text: text, timeout_seconds: timeout || 3.0)
  if json
    print_json(response)
    return
  end
  response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
end

def command_key(args)
  tab_selector, _chars, json, rest, timeout = parse_common(args)
  key = rest.first
  raise "key requires a key name, for example enter or ctrl-c." if key.nil? || key.empty?
  response = send_request(action: "send_key", tab: tab_selector, key: key, timeout_seconds: timeout || 3.0)
  if json
    print_json(response)
    return
  end
  response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
end

def command_create_tab(args)
  _tab_selector, _chars, json, rest, timeout = parse_common(args)
  directory = rest.join(" ")
  response = send_request(
    action: "create_tab",
    directory: directory.empty? ? nil : directory,
    timeout_seconds: timeout || 3.0
  )
  if json
    print_json(response)
    return
  end
  response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
end

def command_ssh_profile(args)
  _tab_selector, _chars, json, rest, timeout = parse_common(args)
  profile = rest.join(" ")
  raise "ssh requires a saved SSH profile name." if profile.empty?
  response = send_request(action: "open_ssh_profile", profile: profile, timeout_seconds: timeout || 3.0)
  if json
    print_json(response)
    return
  end
  response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
end

def command_shortcuts(args)
  _tab_selector, _chars, json, _rest, timeout = parse_common(args)
  response = send_request(action: "list_shortcuts", timeout_seconds: timeout || 3.0)
  unless response["ok"]
    abort(response["error"] || "request failed")
  end
  if json
    print_json(response)
    return
  end
  response.fetch("shortcuts", []).each do |shortcut|
    marker = shortcut["canPlay"] ? "playable" : "blocked"
    puts "#{shortcut["title"]}\t#{shortcut["id"]}\t#{marker}"
  end
end

def command_shortcut(args)
  tab_selector, _chars, json, rest, timeout = parse_common(args)
  shortcut = rest.join(" ")
  raise "shortcut requires a recorded shortcut title." if shortcut.empty?
  response = send_request(
    action: "play_shortcut",
    tab: tab_selector,
    shortcut: shortcut,
    timeout_seconds: timeout || 3.0
  )
  if json
    print_json(response)
    return
  end
  response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
end

def command_tunnels(args)
  _tab_selector, _chars, _json, _rest, _timeout = parse_common(args)
  print_json(session_tunnels_payload(read_state))
end

def session_tunnel_presets_payload(state)
  {
    "schemaVersion" => state["schemaVersion"],
    "snapshotSequence" => state["snapshotSequence"],
    "app" => state["app"],
    "version" => state["version"],
    "sessionTunnelPresets" => state.fetch("sessionTunnelPresets", [])
  }
end

def resolve_session_tunnel_preset(state, selector)
  value = selector.to_s.strip
  return nil if value.empty?
  presets = state.fetch("sessionTunnelPresets", [])
  presets.find { |preset| preset["id"] == value } ||
    presets.find { |preset| preset["id"].to_s.start_with?(value) } ||
    presets.find { |preset| preset["name"] == value } ||
    presets.find { |preset| preset["name"].to_s.casecmp?(value) }
end

def command_tunnel(args)
  tab_selector, _chars, json, rest, timeout = parse_common(args)
  subcommand = rest.shift
  case subcommand
  when "start"
    target_host = nil
    target_port = nil
    local_port = nil
    tunnel_name = nil
    until rest.empty?
      item = rest.shift
      case item
      when "--target-host"
        target_host = rest.shift
      when "--target-port"
        target_port = rest.shift&.to_i
      when "--local-port"
        local_port = rest.shift&.to_i
      when "--name"
        tunnel_name = rest.shift
      else
        raise "unknown tunnel start option: #{item}"
      end
    end
    raise "tunnel start requires --target-host." if target_host.to_s.empty?
    raise "tunnel start requires --target-port." if target_port.nil? || target_port <= 0
    raise "tunnel start requires --local-port." if local_port.nil? || local_port <= 0
    response = send_request(
      action: "start_session_tunnel",
      tab: tab_selector,
      tunnel_name: tunnel_name,
      target_host: target_host,
      target_port: target_port,
      local_port: local_port,
      timeout_seconds: timeout || 3.0
    )
    if json
      print_json(response)
      return
    end
    response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
  when "stop"
    response = send_request(
      action: "stop_session_tunnel",
      tab: tab_selector,
      timeout_seconds: timeout || 3.0
    )
    if json
      print_json(response)
      return
    end
    response["ok"] ? puts(response["message"] || "ok") : abort(response["error"] || "request failed")
  when "list", nil
    command_tunnels(args)
  when "presets", "history"
    print_json(session_tunnel_presets_payload(read_state))
  else
    raise "unknown tunnel subcommand: #{subcommand}"
  end
end

class Hash
  def slice(*keys)
    keys.each_with_object({}) { |key, out| out[key] = self[key] if key?(key) }
  end
end

# The MCP stdio transport delimits messages with newlines, but LSP-style Content-Length
# framing is common enough that we accept either and answer in whichever the client opened with.
MCP_FRAMING = { mode: nil }

def read_mcp_message
  while (line = STDIN.gets)
    line = line.strip
    next if line.empty?

    if line.start_with?("{")
      MCP_FRAMING[:mode] ||= :ndjson
      return JSON.parse(line)
    end

    headers = {}
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
    while (header = STDIN.gets)
      header = header.strip
      break if header.empty?
      key, value = header.split(":", 2)
      headers[key.downcase] = value.strip if key && value
    end
    length = headers["content-length"].to_i
    return nil if length <= 0
    body = STDIN.read(length)
    return nil if body.nil?
    MCP_FRAMING[:mode] ||= :content_length
    return JSON.parse(body.force_encoding(Encoding::UTF_8))
  end
  nil
end

def write_mcp_message(payload)
  MCP_WRITE_LOCK.synchronize do
  body = JSON.generate(payload)
  if MCP_FRAMING[:mode] == :content_length
    STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  else
    STDOUT.write("#{body}\n")
  end
  STDOUT.flush
  end
end

def tool_result_text(text)
  { "content" => [{ "type" => "text", "text" => text.to_s }] }
end

def mcp_tools
  [
    *agent_mcp_tools,
    *wait_mcp_tools,
    *project_mcp_tools,
    {
      "name" => "help",
      "description" => "Read QTerm collaboration instructions first: takeover, background input, renewal, unlock, archives and release.",
      "inputSchema" => { "type" => "object", "properties" => {} }
    },
    *["takeover_tab", "renew_tab_control", "release_tab"].map { |name|
      {
        "name" => name,
        "description" => "#{name}: use a tab UUID from list_tabs. Takeover locks human input for a renewable 120-second lease. Read help first; release when finished.",
        "inputSchema" => {
          "type" => "object", "required" => ["tab"],
          "properties" => { "tab" => { "type" => "string" }, "timeout" => { "type" => "number" } }
        }
      }
    },
    {
      "name" => "list_tabs",
      "description" => "List QTerm tabs and their ids, titles, selection state, size, working directory, and detected shell name.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "metadata" => { "type" => "boolean", "description" => "return schema/version metadata with tabs" }
        }
      }
    },
    {
      "name" => "read_screen",
      "description" => "Read the latest visible screen from a QTerm tab.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "tab" => { "type" => "string", "description" => "selected, 1-based index, id prefix, or title" },
          "chars" => { "type" => "integer", "description" => "maximum tail characters" },
          "metadata" => { "type" => "boolean", "description" => "return JSON with truncation metadata" }
        }
      }
    },
    {
      "name" => "read_history",
      "description" => "Read terminal scrollback/history from a QTerm tab.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "tab" => { "type" => "string" },
          "chars" => { "type" => "integer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON with truncation metadata" }
        }
      }
    },
    {
      "name" => "read_commands",
      "description" => "Read recent structured command blocks from a QTerm tab. Query supports risk:, lifecycle:/state:, boundary:, and text terms.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "tab" => { "type" => "string" },
          "chars" => { "type" => "integer", "description" => "maximum tail characters per command output" },
          "query" => { "type" => "string", "description" => "filter command blocks, for example risk:dangerous lifecycle:failed rm" }
        }
      }
    },
    {
      "name" => "create_tab",
      "description" => "Create a new local QTerm tab, optionally starting in an existing directory.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "directory" => { "type" => "string", "description" => "optional start directory" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "open_ssh_profile",
      "description" => "Open a saved QTerm SSH profile in a new tab by display name.",
      "inputSchema" => {
        "type" => "object",
        "required" => ["profile"],
        "properties" => {
          "profile" => { "type" => "string", "description" => "saved SSH profile display name" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "list_session_tunnels",
      "description" => "List active or recently failed QTerm session tunnels with local and remote endpoints.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {}
      }
    },
    {
      "name" => "start_session_tunnel",
      "description" => "Start a QTerm session tunnel through a tab that is already logged into the deepest reachable server. Supply preset with a saved preset id/name, or supply targetHost, targetPort, and localPort. The local listener binds to 127.0.0.1 only.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "tab" => { "type" => "string", "description" => "selected, 1-based index, id prefix, or title" },
          "preset" => { "type" => "string", "description" => "saved preset id, id prefix, or exact name" },
          "name" => { "type" => "string", "description" => "optional tunnel display name" },
          "targetHost" => { "type" => "string", "description" => "host reachable from the deepest logged-in server" },
          "targetPort" => { "type" => "integer", "description" => "remote target TCP port" },
          "localPort" => { "type" => "integer", "description" => "local 127.0.0.1 listener port on this Mac" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to accept the request" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "list_session_tunnel_presets",
      "description" => "List recently used QTerm session tunnel presets, including id, name, target host/port, local port, last-used time, and use count.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {}
      }
    },
    {
      "name" => "stop_session_tunnel",
      "description" => "Stop the session tunnel occupying a QTerm tab.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "tab" => { "type" => "string", "description" => "selected, 1-based index, id prefix, or title" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to accept the request" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "list_shortcuts",
      "description" => "List recorded QTerm terminal shortcuts with ids, titles, event counts, durations, and whether each can be replayed through MCP.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" }
        }
      }
    },
    {
      "name" => "play_shortcut",
      "description" => "Replay a recorded QTerm terminal shortcut in a tab. Shortcuts containing protected echo-off input are refused.",
      "inputSchema" => {
        "type" => "object",
        "required" => ["shortcut"],
        "properties" => {
          "tab" => { "type" => "string", "description" => "selected, 1-based index, id prefix, or title" },
          "shortcut" => { "type" => "string", "description" => "recorded shortcut title" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "send_text",
      "description" => "Send text to a QTerm tab.",
      "inputSchema" => {
        "type" => "object",
        "required" => ["text"],
        "properties" => {
          "tab" => { "type" => "string" },
          "text" => { "type" => "string" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    },
    {
      "name" => "send_key",
      "description" => "Send a named key/control sequence such as enter, ctrl-c, tab, escape, up, down, left, right.",
      "inputSchema" => {
        "type" => "object",
        "required" => ["key"],
        "properties" => {
          "tab" => { "type" => "string" },
          "key" => { "type" => "string" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for QTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    }
  ]
end

def call_tool(name, args)
  args ||= {}
  return tool_result_text(JSON.pretty_generate(project_tool(args))) if name == "project_layout"
  return tool_result_text(JSON.pretty_generate(wait_tool(args))) if name == "wait_session"
  if ["list_attention", "acknowledge_attention"].include?(name)
    return tool_result_text(JSON.pretty_generate(attention_tool(name, args)))
  end
  if agent_mcp_tools.any? { |tool| tool["name"] == name }
    return tool_result_text(JSON.pretty_generate(agent_request(name, args)))
  end
  case name
  when "help"
    tool_result_text(JSON.pretty_generate({
      "version" => "\#(AppVersion.value)",
      "workflow" => [
        "Call list_tabs and read_screen/read_history/read_commands to inspect the target. Use its explicit UUID for every subsequent operation.",
        "Call takeover_tab(tab: UUID) before operating. Requires paired tool write access in QTerm Settings. Each MCP process has a separate owner identity; another process cannot write or release your lease.",
        "Call send_text or send_key with the same tab UUID. Input does not select the tab or bring QTerm forward. Humans can work in other tabs while observing yours.",
        "The lease expires after 120 seconds without successful input or renew_tab_control. For long commands, renew every 60 seconds while monitoring output. Reads do not renew. Never resend commands just to renew.",
        "Call release_tab in your cleanup/finally path. Normal MCP EOF also attempts release. Terminal exit, tab close and lease expiry release automatically.",
        "Human unlock immediately releases the lease. Delayed input is rejected until explicit new takeover. Stop and coordinate with the human before retaking after unexpected loss of control.",
        "Read aiControlled, aiLeaseExpiresAt and aiRequiresTakeover from list_tabs. After release or expiry, takeover is required for further tool writes to this tab.",
        "Input archives are local JSONL, accessible from Settings > Tools > Open AI archives. Password-mode input is omitted and recognized secrets redacted. Avoid secrets in visible commands. Partial input is buffered until Enter, interrupt or release.",
        "Use a separate tab for tool-driven shortcut playback, file transfer or session tunnels. Controlled tabs support direct send_text/send_key input. Unlock does not interrupt a running shell command."
      ],
      "tools" => mcp_tools
    }))
  when "takeover_tab", "renew_tab_control", "release_tab"
    tab = args.fetch("tab")
    raise "Use an explicit tab UUID from list_tabs." unless tab.match?(/\A[0-9a-fA-F-]{36}\z/)
    response = send_request(action: name, tab: tab, timeout_seconds: args["timeout"] || 3.0)
    raise(response["error"] || "request failed") unless response["ok"]
    if name == "release_tab"
      CONTROLLED_TABS.delete(tab)
    else
      CONTROLLED_TABS[tab] = true
    end
    tool_result_text(JSON.pretty_generate(response))
  when "list_tabs"
    state = read_state
    payload = args["metadata"] ? tabs_payload(state) : tab_summaries(state)
    tool_result_text(JSON.pretty_generate(payload))
  when "read_screen"
    state = read_state
    tab = require_tab(state, args["tab"])
    if args["metadata"]
      tool_result_text(JSON.pretty_generate(text_payload(state, tab, "screen", args["chars"])))
    else
      tool_result_text(tail_chars(tab["screen"], args["chars"]))
    end
  when "read_history"
    state = read_state
    tab = require_tab(state, args["tab"])
    if args["metadata"]
      tool_result_text(JSON.pretty_generate(text_payload(state, tab, "history", args["chars"])))
    else
      tool_result_text(tail_chars(tab["history"], args["chars"]))
    end
  when "read_commands"
    state = read_state
    tab = require_tab(state, args["tab"])
    tool_result_text(JSON.pretty_generate(commands_payload(state, tab, args["chars"], args["query"])))
  when "create_tab"
    response = send_request(
      action: "create_tab",
      directory: args["directory"],
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "open_ssh_profile"
    response = send_request(
      action: "open_ssh_profile",
      profile: args.fetch("profile"),
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "list_session_tunnels"
    state = read_state
    tool_result_text(JSON.pretty_generate(session_tunnels_payload(state)))
  when "list_session_tunnel_presets"
    state = read_state
    tool_result_text(JSON.pretty_generate(session_tunnel_presets_payload(state)))
  when "start_session_tunnel"
    preset = resolve_session_tunnel_preset(read_state, args["preset"])
    raise "Session tunnel preset not found: #{args["preset"]}" if args["preset"] && preset.nil?
    target_host = preset ? preset["targetHost"] : args["targetHost"]
    target_port = preset ? preset["targetPort"] : args["targetPort"]
    local_port = preset ? preset["localPort"] : args["localPort"]
    tunnel_name = args.key?("name") ? args["name"] : preset&.fetch("name", nil)
    raise "start_session_tunnel requires preset or targetHost." if target_host.to_s.empty?
    raise "start_session_tunnel requires preset or targetPort." if target_port.to_i <= 0
    raise "start_session_tunnel requires preset or localPort." if local_port.to_i <= 0
    response = send_request(
      action: "start_session_tunnel",
      tab: args["tab"],
      tunnel_name: tunnel_name,
      target_host: target_host,
      target_port: target_port.to_i,
      local_port: local_port.to_i,
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "stop_session_tunnel"
    response = send_request(
      action: "stop_session_tunnel",
      tab: args["tab"],
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "list_shortcuts"
    response = send_request(
      action: "list_shortcuts",
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(JSON.pretty_generate(response))
  when "play_shortcut"
    response = send_request(
      action: "play_shortcut",
      tab: args["tab"],
      shortcut: args.fetch("shortcut"),
      timeout_seconds: args["timeout"] || 3.0
    )
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "send_text"
    response = send_request(action: "input", tab: args["tab"], text: args.fetch("text"), timeout_seconds: args["timeout"] || 3.0)
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  when "send_key"
    response = send_request(action: "send_key", tab: args["tab"], key: args.fetch("key"), timeout_seconds: args["timeout"] || 3.0)
    raise(response["error"] || "request failed") unless response["ok"]
    tool_result_text(args["metadata"] ? JSON.pretty_generate(response) : (response["message"] || "ok"))
  else
    raise "Unknown tool: #{name}"
  end
end

\#(TerminalMCPDispatcher.script)

\#(TerminalAgentCLI.script)
\#(TerminalRuntimeCLI.script)
\#(TerminalWaitCLI.script)
\#(TerminalProjectCLI.script)

def command_help
  puts <<~HELP
    QTerm CLI

    Commands:
      qterm tabs
      qterm screen [--tab selected|INDEX|ID] [--chars N] [--json]
      qterm history [--tab selected|INDEX|ID] [--chars N] [--json]
      qterm commands [--tab selected|INDEX|ID] [--chars N] [--query QUERY]
      qterm input [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] TEXT
      qterm key [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] enter|ctrl-c|tab|escape|up|down|left|right
      qterm tab [--timeout SECONDS] [--json] [DIRECTORY]
      qterm ssh [--timeout SECONDS] [--json] PROFILE_NAME
      qterm tunnels
      qterm tunnel presets
      qterm tunnel start [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] --target-host HOST --target-port PORT --local-port PORT [--name NAME]
      qterm tunnel stop [--tab selected|INDEX|ID] [--timeout SECONDS] [--json]
      qterm shortcuts [--timeout SECONDS] [--json]
      qterm shortcut [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] SHORTCUT_TITLE
      qterm mcp
      qterm attention [read --item UUID --version N] [--tab UUID]
      qterm wait SPEC_JSON
      qterm project OPERATION [REQUEST_JSON]
      qterm agent bind --tab UUID --kind claude|codex
      qterm agent report --binding PRIVATE_FILE --activity working|idle|blocked|unknown|exited [--block-reason approval|question|other] [--result completed|failed|interrupted|unknown]
      qterm agent status --tab UUID
      qterm agent events [--after CURSOR_JSON] [--limit N]

    MCP config example:
      {"mcpServers":{"qterm":{"command":"qterm","args":["mcp"]}}}
  HELP
end

command = ARGV.shift
begin
  case command
  when "tabs" then command_tabs(ARGV)
  when "agent" then command_agent(ARGV)
  when "attention" then command_attention(ARGV)
  when "wait" then command_wait(ARGV)
  when "project" then command_project(ARGV)
  when "screen" then command_screen(ARGV)
  when "history" then command_history(ARGV)
  when "commands" then command_commands(ARGV)
  when "input" then command_input(ARGV)
  when "key" then command_key(ARGV)
  when "tab" then command_create_tab(ARGV)
  when "ssh" then command_ssh_profile(ARGV)
  when "tunnels" then command_tunnels(ARGV)
  when "tunnel" then command_tunnel(ARGV)
  when "shortcuts" then command_shortcuts(ARGV)
  when "shortcut" then command_shortcut(ARGV)
  when "mcp" then command_mcp
  when nil, "help", "--help", "-h" then command_help
  else
    abort "Unknown command: #{command}"
  end
rescue => e
  abort e.message
end
"""#
}
