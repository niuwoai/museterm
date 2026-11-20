require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

class RuntimeProbeClient
  attr_reader :last_wire_bytes
  def receive(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      if (newline = @buffer.index("\n"))
        raise "Response exceeds protocol budget" if newline > 1_048_576
        line = @buffer.slice!(0..newline)
        @last_wire_bytes = line.bytesize
        return JSON.parse(line)
      end
      raise "Response exceeds protocol budget" if @buffer.bytesize > 1_048_576
      raise "Capacity response timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      bytes = @socket.read_nonblock(16_384, exception: false)
      case bytes
      when :wait_readable then IO.select([@socket],nil,nil,0.1)
      when nil then raise EOFError,"Client disconnected"
      else @buffer << bytes
      end
    end
  end
end

binary,prefix,profile=ARGV
abort "Use HELPER REPORT_PREFIX plain|escaped|control" unless %w[plain escaped control].include?(profile)
root=Dir.mktmpdir("qrt-cap-","/private/tmp")
File.chmod(0o700,root)
directory=root
while directory.bytesize+111 < 1000
  character={"plain"=>"d","escaped"=>"\"","control"=>"\x01"}.fetch(profile)
  directory=File.join(directory,character*110)
end
FileUtils.mkdir_p(directory)
ids=[]
observations=[]
failure=nil
passed=false
service=nil
client=nil
begin
  service=Process.spawn(binary,"--root",root,in:File::NULL,out:File::NULL,err:File::NULL)
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+10
  until File.file?(File.join(root,"ui-capability"))
    raise "Backend not ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.01
  end
  client=RuntimeProbeClient.new(root)
  request=lambda do |action,fields={}|
    response=client.request(action,fields)
    raise "Rejected #{action}: #{response['error']}" unless response["ok"]
    response
  end
  command="\e]777;MuseTerm;start=6563686f206361706163697479\a\e]777;MuseTerm;end=0\a"
  body="STDOUT.sync=true; STDOUT.write(#{(command*8).dump}); sleep 120"
  64.times do |index|
    info=request.call("create",{"launch"=>{"executable"=>"/usr/bin/ruby","arguments"=>["-e",body],"directory"=>directory,"environment"=>{"PATH"=>"/usr/bin:/bin"},"columns"=>80,"rows"=>24}}).fetch("session")
    ids<<info
    grant=request.call("bindAgent",{"sessionID"=>info["id"],"generation"=>info["generation"],"agentKind"=>"willdeep"}).fetch("agentGrant")
    request.call("reportAgent",{"sessionID"=>info["id"],"generation"=>info["generation"],"agentReport"=>grant.merge("sequence"=>1,"activity"=>"working","context"=>{"sessionID"=>SecureRandom.uuid,"taskID"=>"/"*128,"gateID"=>"/"*128})})
    if (index+1)%8==0
      result=request.call("list")
      observations<<{"sessions"=>result.fetch("sessions").length,"wireBytes"=>client.last_wire_bytes,"commandCounts"=>result.fetch("sessions").map{|s|s.fetch("commands",[]).length}}
    end
  end
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+15
  loop do
    result=request.call("list")
    sessions=result.fetch("sessions")
    if sessions.length==64 && sessions.all?{|s|s.fetch("commands",[]).length==8}
      raise "Listed identities differ" unless sessions.map{|s|s.fetch("id")}.sort == ids.map{|s|s.fetch("id")}.sort
      raise "Listed processes differ" unless sessions.all? do |s|
        original=ids.find{|i|i.fetch("id")==s.fetch("id")}
        s["pid"]==original["pid"] && s["generation"]==original["generation"] && s["directory"]==directory && s["running"] &&
          s.dig("agent","activity")=="working" && s.dig("agent","context","taskID")=="/"*128 && s.dig("agent","context","gateID")=="/"*128
      end
      observations<<{"sessions"=>64,"wireBytes"=>client.last_wire_bytes,"commandCounts"=>sessions.map{|s|s.fetch("commands",[]).length}}
      break
    end
    raise "Command projections incomplete" if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.02
  end
  rejected=client.request("create",{"launch"=>{"executable"=>"/bin/sh","arguments"=>["-c","exit 0"],"directory"=>root,"environment"=>{},"columns"=>80,"rows"=>24}})
  raise "65th session was not rejected" unless !rejected["ok"] && rejected["error"]=="resource_limit"
  retained=request.call("list").fetch("sessions")
  raise "Capacity rejection changed existing sessions" unless retained.map{|s|[s["id"],s["pid"],s["generation"]]}.sort==ids.map{|s|[s["id"],s["pid"],s["generation"]]}.sort
  passed=true
rescue=>error
  failure="#{error.class}: #{error.message}"
ensure
  client&.close
  if service
    cleanup=RuntimeProbeClient.new(root)
    ids.each{|s|cleanup.request("close",{"sessionID"=>s["id"],"generation"=>s["generation"],"controlEpoch"=>s["controlEpoch"]})}
    cleanup.request("shutdownIfEmpty")
    cleanup.close
    deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+10
    until Process.waitpid(service,Process::WNOHANG)
      raise "Backend cleanup timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
      sleep 0.02
    end
  end
  report={"passed"=>passed,"failure"=>failure,"profile"=>profile,"createdSessions"=>ids.length,"directoryBytes"=>directory.bytesize,"observations"=>observations,"helperSHA256"=>Digest::SHA256.file(binary).hexdigest,"ownedCleanupVerified"=>true,
    "scope"=>"64 real PTYs with 8 command projections and maximum native Agent context; bounded large list response, 65th rejection; not GUI or WillDeep CLI acceptance"}
  File.write("#{prefix}.json",JSON.pretty_generate(report)+"\n")
  File.write("#{prefix}.md",["# 后台最大会话元数据验证","","通过：#{passed}","失败：#{failure || '无'}","目录类型：#{profile}","真实 PTY：#{ids.length}","目录字节数：#{directory.bytesize}","最大实测帧：#{observations.map{|x|x.fetch('wireBytes')}.max || 0} bytes","",report.fetch("scope"),""].join("\n"))
  FileUtils.remove_entry(root)
  puts JSON.generate(report)
end
exit(passed ? 0 : 1)
