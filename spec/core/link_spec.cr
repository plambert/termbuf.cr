require "../spec_helper"

Spectator.describe TermBuf::Link do
  it "carries a URI and an optional grouping id" do
    link = TermBuf::Link.new "https://example.com", "one"

    expect(link.uri).to eq "https://example.com"
    expect(link.id).to eq "one"
    expect(link.parameters).to eq "id=one"
  end

  it "has an empty parameter field without an id" do
    expect(TermBuf::Link.new("https://example.com").parameters).to eq ""
  end

  # A semicolon would end the field it sits in and the rest of the URI would be
  # read as something else entirely.
  it "refuses a URI or an id that would break the sequence" do
    expect { TermBuf::Link.new "" }.to raise_error ArgumentError
    expect { TermBuf::Link.new "https://example.com/a;b" }.to raise_error ArgumentError
    expect { TermBuf::Link.new "https://example.com", "a;b" }.to raise_error ArgumentError
    expect { TermBuf::Link.new "https://example.com", "a:b" }.to raise_error ArgumentError
  end
end

Spectator.describe TermBuf::LinkTable do
  it "gives the same id to the same link" do
    table = TermBuf::LinkTable.new
    first = table.id "https://example.com"

    expect(table.id "https://example.com").to eq first
    expect(table.size).to eq 1
  end

  it "tells two links apart by their id as well as their URI" do
    table = TermBuf::LinkTable.new

    expect(table.id "https://example.com", "one").not_to eq table.id("https://example.com", "two")
    expect(table.size).to eq 2
  end

  it "never assigns the id that means no link" do
    table = TermBuf::LinkTable.new

    expect(table.id "https://example.com").not_to eq TermBuf::LinkTable::NONE
    expect(table[TermBuf::LinkTable::NONE]?).to be_nil
  end

  it "resolves an id back to what it stands for" do
    table = TermBuf::LinkTable.new
    id = table.id "https://example.com", "one"

    expect(table[id]?.try &.uri).to eq "https://example.com"
    expect(table[id]?.try &.id).to eq "one"
  end

  it "has nothing to say about an id it never assigned" do
    expect(TermBuf::LinkTable.new[99_u32]?).to be_nil
  end
end

Spectator.describe "linked cells" do
  it "interns through the buffer and carries the id on the style" do
    buffer = TermBuf::Buffer.new 20, 2
    id = buffer.link "https://example.com"
    buffer.write 0, 0, "text", TermBuf::Style::DEFAULT.linked(id)

    style = buffer.styles[buffer.back[0, 0].style]
    expect(style.link).to eq id
    expect(buffer.links[style.link]?.try &.uri).to eq "https://example.com"
  end

  # Two runs of one link are one link to the terminal when they share an id,
  # which is what makes a URL wrapped across two rows highlight as a whole.
  it "gives one id to two ranges that name the same group" do
    buffer = TermBuf::Buffer.new 20, 2
    first = buffer.link "https://example.com", "wrapped"
    second = buffer.link "https://example.com", "wrapped"

    expect(first).to eq second
  end
end
