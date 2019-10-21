require_relative 'docbookrx/docbook_visitor'

module Docbookrx
  def self.convert_file infile, opts = {}
    converter = DocbookVisitor.new infile, opts
    converter.run
    converter.finish
  end
end
