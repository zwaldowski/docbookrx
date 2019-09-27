require 'nokogiri'
require_relative 'docbookrx/docbook_visitor'

module Docbookrx
  def self.convert str, opts = {}
    xmldoc = ::Nokogiri::XML::Document.parse(str) do |config|
      config.dtdload
    end
    raise 'Not a parseable document' unless (root = xmldoc.root)
    visitor = DocbookVisitor.new opts
    root.accept visitor
    visitor.after
    visitor.lines * "\n"
  end

  def self.convert_file infile, opts = {}
    outfile = if (ext = ::File.extname infile)
      %(#{infile[0...-ext.length]}.adoc)
    else
      %(#{infile}.adoc)
    end
    
    Dir.chdir(File.dirname(infile)) {
      output = File.open(infile) { |file| convert file, opts }
      ::IO.write outfile, output
      nil
    }
  end
end
