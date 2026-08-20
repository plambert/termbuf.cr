# A small application that draws, reacts to input, and gives the terminal back.
#
#     crystal run examples/clock.cr
#
# Press any key to add a mark; press q to leave.
require "../src/termbuf"

TermBuf::Terminal.open do |terminal|
  marks = [] of String
  frame = 0

  terminal.start_frame_scheduler fps: 20

  loop do
    frame += 1

    terminal.batch do |screen|
      screen.clear
      screen.write 2, 1, "TermBuf", TermBuf::Style::DEFAULT.bold
      screen.write 2, 2, "#{terminal.size} frame #{frame}",
        TermBuf::Style::DEFAULT.fg(TermBuf::Color.rgb(120, 180, 250))
      screen.write 2, 4, marks.last(10).join(' ')
      screen.write 2, terminal.size.rows - 2, "press q to quit",
        TermBuf::Style::DEFAULT.faint
    end

    select
    when event = terminal.events.receive?
      case event
      in TermBuf::Events::Input
        text = String.new event.bytes
        break if text.includes? 'q'
        marks << text.inspect
      in TermBuf::Events::Resize then terminal.paint!
      in TermBuf::Events::Closed then break
      in TermBuf::Events::Response, TermBuf::Events::Warning, TermBuf::Events::Failure
        marks << event.class.name.split("::").last
      in Nil then break
      end
    when timeout 50.milliseconds
      # Nothing happened; the scheduler keeps the screen current.
    end
  end
end

puts "terminal restored"
