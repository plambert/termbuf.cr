require "../spec_helper"

# A whole terminal, opened in a Windows pseudoconsole this spec plays the
# terminal for. Windows Terminal and WezTerm host programs in the same kind of
# console, so this checks the probe, the paint and the resize stage against
# the real thing, without a window.
{% skip_file unless flag?(:win32) %}

require "file_utils"
require "termbuf-input/win32/pseudo_console"

private module TerminalTarget
  # Built once, the first time it is wanted. The compile takes a while.
  def self.path : Path
    @@path ||= build
  end

  @@path : Path? = nil

  private def self.build : Path
    root = Path[__DIR__].parent.parent
    directory = Path[File.tempname "termbuf-conpty", nil]
    Dir.mkdir_p directory
    at_exit { FileUtils.rm_rf directory.to_s }

    built = directory / "terminal_target.exe"
    said = IO::Memory.new
    status = Process.run "crystal", ["build", "--no-debug", "-o", built.to_s, "spec/support/terminal_target.cr"],
      output: said, error: said, chdir: root.to_s
    raise "building the terminal target failed:\n#{said}" unless status.success?

    built
  end
end

private class TerminalSession
  getter console : TermBuf::Input::PseudoConsole
  getter log : Path

  def initialize(columns = 80, rows = 24)
    @log = TerminalTarget.path.parent / "log-#{Random.rand UInt32}.txt"
    @console = TermBuf::Input::PseudoConsole.new TerminalTarget.path.to_s, [@log.to_s], columns, rows
  end

  def lines : Array(String)
    File.exists?(@log) ? File.read_lines(@log) : [] of String
  end

  # Waits up to *timeout* for a log line that *line* matches.
  def wait_for(line : String | Regex, timeout : Time::Span = 10.seconds) : String?
    deadline = Time.instant + timeout
    until Time.instant >= deadline
      found = lines.find { |logged| line.is_a?(Regex) ? logged.matches?(line) : logged == line }
      return found if found
      sleep 20.milliseconds
    end
  end

  def close : Nil
    @console.close
  end
end

private def with_terminal(columns = 80, rows = 24, &)
  session = TerminalSession.new columns, rows
  begin
    raise "the terminal never got ready: #{session.lines}" unless session.wait_for("ready")
    yield session
  ensure
    session.close
  end
end

Spectator.describe "a terminal in a Windows pseudoconsole" do
  # The probe asks a dozen questions and waits for a sentinel. A console
  # that answers none of them must still let the terminal open.
  it "opens at the console's size, in well under a second" do
    with_terminal(80, 24) do |session|
      opened = session.lines.first
      expect(opened).to start_with "opened 80x24 in "
      expect(opened.match(/in (\d+)ms/).try(&.[1].to_i) || 99999).to be < 1000
    end
  end

  it "paints what it was given" do
    with_terminal do |session|
      deadline = Time.instant + 5.seconds
      until session.console.screen.includes?("hello from termbuf") || Time.instant >= deadline
        sleep 20.milliseconds
      end

      expect(session.console.screen).to contain "hello from termbuf"
    end
  end

  it "answers a resize with one Events::Resize carrying the size it left" do
    with_terminal(80, 24) do |session|
      session.console.resize 100, 30
      expect(session.wait_for("resize 100x30 previous 80x24")).not_to be_nil
    end
  end

  it "gives the console back on q" do
    with_terminal do |session|
      session.console.type "q"
      expect(session.console.wait(10.seconds)).to eq 0
      expect(session.lines.last).to eq "restored"
    end
  end
end
