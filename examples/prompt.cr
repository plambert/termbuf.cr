# The simplest thing an input field is for: ask a question, get an answer back.
#
#     crystal run examples/prompt.cr
#
# `Field#run` owns the event loop, so this is the whole application. Type,
# press enter to answer, escape or Ctrl+C to give up. The up and down arrows
# walk back through what has been answered before, tab completes a colour, and
# pasted text goes in as text.
require "../src/termbuf"

COLOURS = %w[amber azure carmine cerulean chartreuse cobalt crimson indigo
  magenta ochre saffron scarlet sienna teal ultramarine vermilion]

answers = [] of String

TermBuf::Terminal.open do |terminal|
  accent = TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(120, 180, 250)

  editor = TermBuf::Editor.new(
    history: TermBuf::History.new(search: TermBuf::History::Search::Prefix),
    completions: ->(request : TermBuf::Completion::Request) do
      TermBuf::Completion::Result.new COLOURS.select(&.starts_with? request.word)
    end)

  field = TermBuf::Field.new(
    bounds: TermBuf::Rect.new(0, terminal.size.rows - 3, terminal.size.columns, 3),
    editor: editor,
    border: TermBuf::Border.rounded(title: " a colour "),
    prompt: TermBuf::Field::Prompt.new("› ", accent),
    growth: TermBuf::Field::Growth::Grow,
    max_rows: 8,
    placeholder: "tab completes, up walks back, enter answers")

  # `#run` returns what was entered, or nil when it was given up on.
  while answer = field.run terminal
    answers << answer
  end
end

puts answers.empty? ? "nothing entered" : answers.join('\n')
