import Foundation

enum TerminalPreviewCLI {
    static let script = #"""
def preview_tool(args)
  raise "Preview request must be an object." unless args.is_a?(Hash)
  tab = explicit_agent_tab(args["tab"])
  seconds = Float(args.fetch("timeout", 5))
  raise "Preview timeout must be between 0.1 and 60 seconds." unless seconds.finite? && (0.1..60).cover?(seconds)
  metadata = read_private_runtime_json(File.join(ROOT, "runtime.json"), RUNTIME_METADATA_MAX_BYTES)
  fields = args.select { |key, _| %w[path markdown close].include?(key) }
  raise "Provide exactly one of path, markdown or close:true." unless fields.length == 1 && (!fields.key?("close") || fields["close"] == true)
  raise "Markdown exceeds 2 MiB." if fields["markdown"] && (!fields["markdown"].is_a?(String) || fields["markdown"].bytesize > 2 * 1024 * 1024)
  fields["uiEpoch"] = explicit_agent_tab(metadata["appEpoch"])
  fields["deadlineMonotonic"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  response = send_request(action: "preview", tab: tab, preview_request: fields, timeout_seconds: seconds)
  raise(response["error"] || "Preview request failed.") unless response["ok"]
  response
end

def command_preview(args)
  tab = nil
  if (index = args.index("--tab"))
    raise "--tab requires a source terminal UUID." unless args[index + 1]
    tab = args[index + 1]; args.slice!(index, 2)
  end
  if tab.nil? && ENV["MUSETERM_AGENT_CONTEXT"]
    context = read_private_runtime_json(ENV.fetch("MUSETERM_AGENT_CONTEXT"), RUNTIME_METADATA_MAX_BYTES)
    tab = context["tabID"]
  end
  raise "Use museterm preview [--tab UUID] FILE|--stdin|--close." unless args.length == 1
  fields = case args.first
  when "--close" then {"close" => true}
  when "--stdin"
    text = STDIN.read(2 * 1024 * 1024 + 1)
    raise "Markdown exceeds 2 MiB." if text.bytesize > 2 * 1024 * 1024
    text.force_encoding(Encoding::UTF_8)
    raise "Markdown input must be valid UTF-8." unless text.valid_encoding?
    {"markdown" => text}
  else {"path" => File.expand_path(args.first)}
  end
  print_json(preview_tool(fields.merge("tab" => tab)))
end

def preview_mcp_tools
  [{"name" => "preview",
    "description" => "Show a local image/Markdown file or supplied Markdown in MuseTerm's source-bound preview panel. Exact source terminal UUID, pairing and enabled writes required. Does not select a tab, send terminal input or take control. UI must be online; ok acknowledges acceptance, not rendering completion. For SSH use markdown text, not a remote path. Remote images load only on explicit human action.",
    "inputSchema" => {"type" => "object", "required" => ["tab"], "additionalProperties" => false,
      "properties" => {"tab" => {"type" => "string"}, "path" => {"type" => "string", "description" => "Absolute local image or Markdown file path"},
        "markdown" => {"type" => "string"}, "close" => {"type" => "boolean"}, "timeout" => {"type" => "number"}}}}]
end
"""#
}
