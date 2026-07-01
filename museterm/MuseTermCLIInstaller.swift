import Foundation

enum MuseTermCLIInstaller {
    static let installDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)
    static let installURL = installDirectory.appendingPathComponent("museterm")

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
# MuseTerm CLI and MCP bridge.
# Installed by MuseTerm. Safe to replace on app updates.

require "json"
require "securerandom"
require "fileutils"
require "time"
require "shellwords"
require "timeout"

ROOT = File.expand_path("~/Library/Application Support/MuseTerm/Tools")
STATE = File.join(ROOT, "state.json")
REQUESTS = File.join(ROOT, "requests")
RESPONSES = File.join(ROOT, "responses")

def ensure_dirs
  FileUtils.mkdir_p(REQUESTS)
  FileUtils.mkdir_p(RESPONSES)
end

def read_state
  raise "MuseTerm is not publishing tool state yet. Open MuseTerm first." unless File.file?(STATE)
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

def tab_summaries(state)
  state.fetch("tabs", []).map { |tab|
    tab.slice("id", "index", "title", "subtitle", "currentDirectory", "shellName", "isSelected", "state", "columns", "rows", "updatedAt")
  }
end

def tabs_payload(state)
  {
    "schemaVersion" => state["schemaVersion"],
    "app" => state["app"],
    "version" => state["version"],
    "snapshotSequence" => state["snapshotSequence"],
    "selectedTabID" => state["selectedTabID"],
    "tabs" => tab_summaries(state)
  }
end

def send_request(action:, tab: nil, text: nil, key: nil, bytes: nil, timeout_seconds: 3.0)
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
    "bytes" => bytes
  }.compact
  File.write(File.join(REQUESTS, "#{id}.json"), JSON.generate(request))
  response_path = File.join(RESPONSES, "#{id}.json")

  Timeout.timeout(timeout_seconds) do
    loop do
      if File.file?(response_path)
        response = JSON.parse(File.read(response_path))
        FileUtils.rm_f(response_path)
        return response
      end
      sleep 0.05
    end
  end
rescue Timeout::Error
  raise "MuseTerm did not answer the tool request in time."
end

def require_tab(state, selector)
  tab = selected_tab(state, selector)
  raise "No MuseTerm tab matched #{selector.inspect}." unless tab
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

def filter_command_blocks(blocks, query)
  filters = command_query_filters(query)
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
  filtered_blocks = filter_command_blocks(source_blocks, query)
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

class Hash
  def slice(*keys)
    keys.each_with_object({}) { |key, out| out[key] = self[key] if key?(key) }
  end
end

def read_mcp_message
  headers = {}
  while (line = STDIN.gets)
    line = line.chomp
    break if line.empty?
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
  end
  return nil if headers.empty?
  length = headers["content-length"].to_i
  return nil if length <= 0
  JSON.parse(STDIN.read(length))
end

def write_mcp_message(payload)
  body = JSON.generate(payload)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
end

def tool_result_text(text)
  { "content" => [{ "type" => "text", "text" => text.to_s }] }
end

def mcp_tools
  [
    {
      "name" => "list_tabs",
      "description" => "List MuseTerm tabs and their ids, titles, selection state, size, working directory, and detected shell name.",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "metadata" => { "type" => "boolean", "description" => "return schema/version metadata with tabs" }
        }
      }
    },
    {
      "name" => "read_screen",
      "description" => "Read the latest visible screen from a MuseTerm tab.",
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
      "description" => "Read terminal scrollback/history from a MuseTerm tab.",
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
      "description" => "Read recent structured command blocks from a MuseTerm tab. Query supports risk:, lifecycle:/state:, boundary:, and text terms.",
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
      "name" => "send_text",
      "description" => "Send text to a MuseTerm tab.",
      "inputSchema" => {
        "type" => "object",
        "required" => ["text"],
        "properties" => {
          "tab" => { "type" => "string" },
          "text" => { "type" => "string" },
          "timeout" => { "type" => "number", "description" => "seconds to wait for MuseTerm to answer" },
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
          "timeout" => { "type" => "number", "description" => "seconds to wait for MuseTerm to answer" },
          "metadata" => { "type" => "boolean", "description" => "return JSON response metadata" }
        }
      }
    }
  ]
end

def call_tool(name, args)
  args ||= {}
  case name
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

def command_mcp
  ensure_dirs
  while (message = read_mcp_message)
    id = message["id"]
    method = message["method"]
    params = message["params"] || {}

    next if id.nil? && method&.start_with?("notifications/")

    begin
      result = case method
      when "initialize"
        {
          "protocolVersion" => "2024-11-05",
          "serverInfo" => { "name" => "museterm", "version" => "\#(AppVersion.value)" },
          "capabilities" => { "tools" => {} }
        }
      when "tools/list"
        { "tools" => mcp_tools }
      when "tools/call"
        call_tool(params.fetch("name"), params["arguments"] || {})
      else
        raise "Unsupported MCP method: #{method}"
      end
      write_mcp_message("jsonrpc" => "2.0", "id" => id, "result" => result)
    rescue => e
      write_mcp_message(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => { "code" => -32000, "message" => e.message }
      )
    end
  end
end

def command_help
  puts <<~HELP
    MuseTerm CLI

    Commands:
      museterm tabs
      museterm screen [--tab selected|INDEX|ID] [--chars N] [--json]
      museterm history [--tab selected|INDEX|ID] [--chars N] [--json]
      museterm commands [--tab selected|INDEX|ID] [--chars N] [--query QUERY]
      museterm input [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] TEXT
      museterm key [--tab selected|INDEX|ID] [--timeout SECONDS] [--json] enter|ctrl-c|tab|escape|up|down|left|right
      museterm mcp

    MCP config example:
      {"mcpServers":{"museterm":{"command":"museterm","args":["mcp"]}}}
  HELP
end

command = ARGV.shift
begin
  case command
  when "tabs" then command_tabs(ARGV)
  when "screen" then command_screen(ARGV)
  when "history" then command_history(ARGV)
  when "commands" then command_commands(ARGV)
  when "input" then command_input(ARGV)
  when "key" then command_key(ARGV)
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
