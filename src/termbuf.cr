require "./termbuf/version"
require "./termbuf/unicode/grapheme"

# TermBuf decouples a terminal application's UI from the terminal itself by
# maintaining an in-memory buffer of the screen and repainting it with a diff
# that minimizes the bytes sent to the terminal.
module TermBuf
end
