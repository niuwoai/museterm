import Foundation

enum TerminalProjectCLI {
    static let script = #"""
PROJECT_OPERATIONS = %w[list createProject renameProject createTab split moveTerminal moveTab reorderProjects reorderTabs resizeSplit focus closeTerminal closeTab closeProject].freeze
PROJECT_REQUEST_CLOCK = Process::CLOCK_MONOTONIC

def project_tool(args)
  raise "Invalid project request." unless args.is_a?(Hash) && PROJECT_OPERATIONS.include?(args["operation"])
  seconds = Float(args.fetch("timeout", 5))
  raise "Project timeout must be between 0.1 and 60 seconds." unless seconds.finite? && (0.1..60).cover?(seconds)
  metadata = read_private_runtime_json(File.join(ROOT, "runtime.json"), RUNTIME_METADATA_MAX_BYTES)
  epoch = explicit_agent_tab(metadata["appEpoch"])
  input = args.reject { |key, _| key == "timeout" }
  input = input.merge("uiEpoch" => epoch, "deadlineMonotonic" => Process.clock_gettime(PROJECT_REQUEST_CLOCK) + seconds)
  response = send_request(action: "project_layout", project_request: input, timeout_seconds: seconds)
  raise(response["error"] || "Project operation failed.") unless response["ok"]
  response
end

def command_project(args)
  operation = args.shift || "list"
  raise "Use museterm project OPERATION [REQUEST_JSON]." if args.length > 1
  fields = args.empty? ? {} : JSON.parse(args.shift)
  raise "Project request must be an object." unless fields.is_a?(Hash)
  print_json(project_tool(fields.merge("operation" => operation)))
rescue JSON::ParserError
  raise "Invalid project request JSON."
end

def project_mcp_tools
  [{"name" => "project_layout",
    "description" => "Query or organize projects, layout tabs and split terminal panes by exact UUID. Mutations require pairing and enabled writes. Background operations preserve current focus and unread items unless focus:true; explicit focus is a separate operation. Creation returns layout identity, not proof of process readiness. Close requires terminateRunning:true for running terminals; processClosure:requested is not a backend termination ACK. Optional workspaceID/expectedEpoch/expectedRevision reject stale targets. UI must be online.",
    "inputSchema" => {"type" => "object", "properties" => {
      "operation" => {"type" => "string", "enum" => PROJECT_OPERATIONS},
      "projectID" => {"type" => "string", "format" => "uuid"},
      "layoutTabID" => {"type" => "string", "format" => "uuid"},
      "terminalID" => {"type" => "string", "format" => "uuid"},
      "splitID" => {"type" => "string", "format" => "uuid"},
      "workspaceID" => {"type" => "string", "format" => "uuid"},
      "expectedEpoch" => {"type" => "string", "format" => "uuid"},
      "expectedRevision" => {"type" => "integer", "minimum" => 0},
      "name" => {"type" => "string", "minLength" => 1, "maxLength" => 120},
      "directory" => {"type" => "string"}, "axis" => {"type" => "string", "enum" => ["horizontal", "vertical"]},
      "ratio" => {"type" => "number", "minimum" => 0.1, "maximum" => 0.9},
      "order" => {"type" => "array", "items" => {"type" => "string", "format" => "uuid"}, "uniqueItems" => true},
      "focus" => {"type" => "boolean"}, "terminateRunning" => {"type" => "boolean"},
      "timeout" => {"type" => "number", "minimum" => 0.1, "maximum" => 60}}, "required" => ["operation"]}}]
end
"""#
}
