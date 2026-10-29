import Foundation

enum TerminalMCPDispatcher {
    static let script = #"""
def mcp_result(method, params)
  case method
  when "initialize"
    {"protocolVersion" => "2024-11-05", "serverInfo" => {"name" => "museterm", "version" => "\#(AppVersion.value)"}, "capabilities" => {"tools" => {}}}
  when "ping" then {}
  when "tools/list" then {"tools" => mcp_tools}
  when "tools/call" then call_tool(params.fetch("name"), params["arguments"] || {})
  else raise "Unsupported MCP method: #{method}"
  end
end

def command_mcp
  jobs = {}
  jobs_lock = Mutex.new
  ensure_dirs
  while (message = read_mcp_message)
    id, method = message["id"], message["method"]
    params = message["params"] || {}
    if id.nil? && method == "notifications/cancelled"
      jobs_lock.synchronize do
        job = jobs[params["requestId"]]
        if job
          job[:cancelled] = true
          job[:thread]&.raise(MuseTermWaitCancelled) if job[:thread]&.alive?
        end
      end
      next
    end
    next if id.nil? && method&.start_with?("notifications/")
    if method == "tools/call" && params["name"] == "wait_session"
      rejected = jobs_lock.synchronize { jobs.length >= 16 || jobs.key?(id) }
      if rejected
        write_mcp_message({"jsonrpc" => "2.0", "id" => id, "error" => {"code" => -32000, "message" => "Too many waits or duplicate request ID."}})
        next
      end
      job = {cancelled: false}
      jobs_lock.synchronize { jobs[id] = job }
      thread = Thread.new(id, params, job) do |job_id, job_params, record|
        begin
          raise MuseTermWaitCancelled if record[:cancelled]
          result = mcp_result("tools/call", job_params)
          write_mcp_message({"jsonrpc" => "2.0", "id" => job_id, "result" => result}) unless record[:cancelled]
        rescue MuseTermWaitCancelled
          # MCP cancellation is fire-and-forget: do not send a cancelled response.
        rescue StandardError => error
          write_mcp_message({"jsonrpc" => "2.0", "id" => job_id, "error" => {"code" => -32000, "message" => error.message}}) unless record[:cancelled]
        ensure
          jobs_lock.synchronize { jobs.delete(job_id) if jobs[job_id].equal?(record) }
        end
      end
      thread.report_on_exception = false
      jobs_lock.synchronize { job[:thread] = thread }
      next
    end
    begin
      write_mcp_message({"jsonrpc" => "2.0", "id" => id, "result" => mcp_result(method, params)})
    rescue StandardError => error
      write_mcp_message({"jsonrpc" => "2.0", "id" => id, "error" => {"code" => -32000, "message" => error.message}})
    end
  end
ensure
  threads = jobs_lock.synchronize do
    jobs.values.map do |job|
      job[:cancelled] = true
      job[:thread]&.raise(MuseTermWaitCancelled) if job[:thread]&.alive?
      job[:thread]
    end.compact
  end
  threads.each { |thread| thread.join(1) }
  CONTROLLED_TABS.keys.each do |tab|
    begin
      send_request(action: "release_tab", tab: tab, timeout_seconds: 0.5)
    rescue StandardError
      # Lease expiry is the fallback; stdout remains exclusively MCP frames.
    end
  end
end
"""#
}
