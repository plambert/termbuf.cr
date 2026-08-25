# A small application that draws, reacts to input, and gives the terminal back.
#
#     crystal run examples/clock.cr
#
# Type to see what arrives; arrow keys, modifiers, and pasted text included.
# Press q to leave.
require "../src/termbuf"

TermBuf::Terminal.open do |terminal|
  seen = [] of String
  frame = 0

  # Nothing is registered as a reply, so every escape sequence arriving from
  # the terminal is a key someone pressed. An application that queries the
  # terminal registers the shape of the answer it is waiting for:
  #
  #     terminal.expect_response "\e[?", "$y"
  #
  # and that one sequence then arrives as `Events::Response` instead.

  terminal.start_frame_scheduler fps: 20

  loop do
    frame += 1
    accent = TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(120, 180, 250)

    terminal.batch do |screen|
      screen.clear
      screen.write 2, 1, "TermBuf", TermBuf::Style::DEFAULT.bold
      screen.write 2, 2, "#{terminal.size}  frame #{frame}", accent
      screen.write 2, 3, "#{terminal.capabilities.flags.to_s.count('|') + 1} capabilities",
        TermBuf::Style::DEFAULT.faint

      seen.last(8).each_with_index do |line, offset|
        screen.write 4, 5 + offset, line
      end

      screen.write 2, terminal.size.rows - 2, "press q to quit",
        TermBuf::Style::DEFAULT.faint
    end

    select
    when event = terminal.events.receive?
      case event
      in TermBuf::Events::Key
        break if event.key.is? 'q'
        seen << "key       #{event.key}  #{String.new(event.bytes).inspect}"
      in TermBuf::Events::Paste
        seen << "paste     #{event.text.inspect}#{event.complete ? "" : "  (never closed)"}"
      in TermBuf::Events::Pasting
        seen << "pasting   #{event.bytes} bytes so far"
      in TermBuf::Events::Response
        seen << "response  #{String.new(event.bytes).inspect}"
      in TermBuf::Events::Resize
        seen << "resize    #{event.size}"
      in TermBuf::Events::Warning
        seen << "warning   #{event.message}"
      in TermBuf::Events::Failure
        seen << "failure   #{event.error.message}"
      in TermBuf::Events::Closed
        break
      in Nil
        break
      end
    when timeout 50.milliseconds
      # Nothing happened; the scheduler keeps the screen current.
    end
  end
end

puts "terminal restored"
