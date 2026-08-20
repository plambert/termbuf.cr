require "./spec_helper"

Spectator.describe TermBuf do
  describe "VERSION" do
    it "matches the version declared in shard.yml" do
      expect(TermBuf::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end
end
