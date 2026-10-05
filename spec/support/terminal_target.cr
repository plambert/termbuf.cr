# The program the pseudoconsole specs run: a whole terminal, opened the way
# an application opens one, probe and all. One line in the log named as the
# first argument for each thing worth checking. Ends on q.
require "../../src/termbuf"

log = File.new ARGV[0], "w"
log.sync = true
started = Time.instant

TermBuf::Terminal.open do |terminal|
  log.puts "opened #{terminal.size} in #{started.elapsed.total_milliseconds.round.to_i}ms"
  log.puts "alternate screen #{terminal.capabilities.includes? TermBuf::Capability::AltScreen}"

  terminal.write 2, 1, "hello from termbuf"
  terminal.paint
  log.puts "ready"

  loop do
    case event = terminal.events.receive?
    when Nil, TermBuf::Events::Closed
      break
    when TermBuf::Events::Resize
      log.puts "resize #{event.size} previous #{event.previous}"
    when TermBuf::Events::Key
      log.puts "key #{event.key}"
      break if event.key.is? 'q'
    end
  end
end

log.puts "restored"
