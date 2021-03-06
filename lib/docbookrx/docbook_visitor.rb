require 'nokogiri'
require 'pathname'

module Docbookrx

class DocbookVisitor
  # transfer node type constants from Nokogiri
  ::Nokogiri::XML::Node.constants.grep(/_NODE$/).each do |sym|
    const_set sym, (::Nokogiri::XML::Node.const_get sym)
  end

  DocbookNs = 'http://docbook.org/ns/docbook'
  XlinkNs = 'http://www.w3.org/1999/xlink'
  IndentationRx = /^[[:blank:]]+/
  LeadingSpaceRx = /\A\s/
  LeadingEndlinesRx = /\A\n+ */
  TrailingEndlinesRx = /\n+\z/
  FirstLineIndentRx = /\A[[:blank:]]*/
  WrappedIndentRx = /\n[[:blank:]]*/
  OnlyWhitespaceRx = /\A\s*\Z/m
  PrevAdjacentChar = /\S\Z/
  NextAdjacentChar = /\A\S/

  EmptyString = String.new("")

  EOL = "\n"

  ENTITY_TABLE = {
     169 => '(C)',
     174 => '(R)',
    8201 => ' ', # thin space
    8212 => '--',
    8216 => '\'',
    8217 => '\'',
    8220 => '"`',
    8221 => '`"',
    8230 => '...',
    8482 => '(TM)',
    8592 => '<-',
    8594 => '->',
    8656 => '<=',
    8658 => '=>'
  }

  REPLACEMENT_TABLE = {
    ':: ' => '{two-colons} ',
    ' – ' => ' -- '
  }

  PARA_TAG_NAMES = ['para', 'simpara']

  #COMPLEX_PARA_TAG_NAMES = ['formalpara', 'para']

  ADMONITION_NAMES = ['note', 'tip', 'warning', 'caution', 'important']

  NORMAL_SECTION_NAMES = ['section', 'simplesect', 'sect1', 'sect2', 'sect3', 'sect4', 'sect5']

  SPECIAL_SECTION_NAMES = ['abstract', 'appendix', 'bibliography', 'glossary', 'preface', 'dedication', 'acknowledgements']

  DOCUMENT_NAMES = ['article', 'book']

  SECTION_NAMES = DOCUMENT_NAMES + ['chapter', 'part'] + NORMAL_SECTION_NAMES + SPECIAL_SECTION_NAMES

  ANONYMOUS_LITERAL_NAMES = ['abbrev', 'acronym', 'code', 'command', 'computeroutput', 'database', 'literal', 'tag', 'userinput']

  NAMED_LITERAL_NAMES = ['classname', 'constant', 'envar', 'exceptionname', 'function', 'interfacename', 'methodname', 'option', 'parameter', 'property', 'replaceable', 'type', 'varname']

  LITERAL_NAMES = ANONYMOUS_LITERAL_NAMES + NAMED_LITERAL_NAMES

  FORMATTING_NAMES = LITERAL_NAMES + ['emphasis']

  KEYWORD_NAMES = ['package', 'firstterm', 'citetitle']

  PATH_NAMES = ['directory', 'filename', 'systemitem']

  UI_NAMES = ['application', 'guibutton', 'guilabel', 'menuchoice', 'guimenu', 'keycap', 'guimenuitem']

  LIST_NAMES = ['itemizedlist', 'orderedlist', 'variablelist', 'procedure', 'substeps', 'stepalternatives' ]

  IGNORED_NAMES = ['title', 'subtitle', 'toc', 'attribution', 'authorgroup', 'itermset', 'publishername', 'cover', 'orgname', 'printhistory', 'keywordset', 'subjectset']
  
  PASSTHROUGH_NAMES = ['guiicon', 'legalnotice']

  attr_reader :lines
  attr_reader :output
  attr_accessor :ids_used_for_xrefs

  def initialize input, opts = {}
    @input = File.absolute_path(input)
    @output = default_output(@input)
    @opts = opts
    @lines = []
    @level = 1
    @skip = {}
    @requires_index = false
    @found_index = false
    @continuation = false
    @adjoin_next = false
    # QUESTION why not handle idprefix and idseparator as attributes (delete on read)?
    @normalize_ids = opts.fetch :normalize_ids, true
    @compat_mode = opts[:compat_mode]
    @attributes = opts[:attributes] || {}
    @idprefix = opts[:idprefix] || @attributes[:idprefix] || '_'
    @idseparator = opts[:idseparator] || @attributes[:idseparator] || '_'
    @sentence_per_line = opts.fetch :sentence_per_line, true
    @preserve_line_wrap = if @sentence_per_line
      false
    else
      opts.fetch :preserve_line_wrap, true
    end
    @delimit_source = opts.fetch :delimit_source, true
    @list_depth = 0
    @in_table = false
    @nested_formatting = []
    @last_added_was_special = false
    @ids_used_for_xrefs = Set.new
    @child_visitors = []
  end

  ## Traversal methods

  # Main processor loop
  def visit node
    return if node.instance_variable_defined? :@skip

    name = node.name
    visit_method_name = case node.type
    when PI_NODE
      :visit_pi
    when ENTITY_REF_NODE
      :visit_entity_ref
    when COMMENT_NODE
      :visit_comment
    else
      if ADMONITION_NAMES.include? name
        :process_admonition
      elsif LITERAL_NAMES.include? name
        :process_literal
      elsif KEYWORD_NAMES.include? name
        :process_keyword
      elsif PATH_NAMES.include? name
        :process_path
      elsif UI_NAMES.include? name
        :process_ui
      elsif NORMAL_SECTION_NAMES.include? name
        :process_section
      elsif SPECIAL_SECTION_NAMES.include? name
        :process_special_section
      else
        %(visit_#{name}).to_sym
      end
    end

    before_traverse node, visit_method_name if (respond_to? :before_traverse)
    result = if respond_to? visit_method_name
      send visit_method_name, node
    elsif respond_to? :default_visit
      send :default_visit, node
    end

    traverse_children node if result == true
    after_traverse node, visit_method_name if (respond_to? :after_traverse)
  end

  def after
    replace_ifdef_lines
    rstrip_lines
    drop_empty_lines
    remove_unused_ids

    @child_visitors.each { |child|
      child.ids_used_for_xrefs = @ids_used_for_xrefs
      child.after
    }
  end

  def traverse_children node, opts = {}
    (opts[:using_elements] ? node.elements : node.children).each do |child|
      child.accept self
    end
  end
  
  alias :proceed :traverse_children

  PASSTHROUGH_NAMES.each do |name|
    method_name = "visit_#{name}".to_sym
    alias_method method_name, :proceed
  end

  ## Text extraction and processing methods

  def text node, unsub = true
    if node
      out = nil;
      if node.is_a? ::Nokogiri::XML::Node
        out = unsub ? reverse_subs(node.text) : node.text
      elsif node.is_a? ::Nokogiri::XML::NodeSet && (first = node.first)
        out = unsub ? reverse_subs(first.text) : first.text
      end
      if ! out.nil? && @in_table
        out.gsub(/\|/, '\|')
      else 
        out
      end
    else
      nil
    end
  end

  def text_at_css node, css, unsub = true
    text (node.at_css css, unsub)
  end

  def format_text node
    if node && (node.is_a? ::Nokogiri::XML::NodeSet)
      node = node.first
    end

    if node.is_a? ::Nokogiri::XML::Node
      append_blank_line
      last_line = lines.length
      proceed node
      @lines.pop(lines.length-last_line+1)
    else
      nil
    end
  end

  def format_text_at_css node, css
    format_text (node.at_css css)
  end

  def entity number
    [number].pack 'U*'
  end

  # Replaces XML entities, and other encoded forms that AsciiDoc automatically
  # applies, with their plain-text equivalents.
  #
  # This method effectively undoes the inline substitutions that AsciiDoc performs.
  #
  # str - The String to processes
  #
  # Examples
  #
  #   reverse_subs "&#169; Acme, Inc."
  #   # => "(C) Acme, Inc."
  #
  # Returns The processed String
  def reverse_subs str
    ENTITY_TABLE.each do |num, text|
      str = str.gsub((entity num), text)
    end
    REPLACEMENT_TABLE.each do |original, replacement|
      str = str.gsub original, replacement
    end
    str
  end

  def format_name node
    if (eponymous_node = (node.at_css '> personname') || (node.at_css '> orgname')) && eponymous_node.elements.empty?
      text eponymous_node
    else
      first_name = (node.at_css '> firstname') || (node.at_css '> personname > firstname')
      last_name = (node.at_css '> surname') || (node.at_css '> personname > surname')
      author = [first_name, last_name].compact * ' '
    end
  end

  def format_authors node
    authors = []
    (node.css 'author').each do |author_node|
      author = format_name author_node
      authors << author unless author.empty?
    end
    authors
  end
  
  def format_listing text
    text.gsub!(/\A\s+\n/, "")
    text.gsub!(/^-\n\+\n/, "\n")
    text.gsub!(/$\s+(-|\+)?\s*\z/, "")
    text = text.each_line.map { |line|
      line.rstrip
    }.join("\n")
    text
  end

  ## Writer methods

  def append_line line = '', unsub = false
    line = reverse_subs line if !line.empty? && unsub
    @lines << line
  end

  def format_append_line node, suffix=""
    text = format_text node
    line = text.shift(1)[0]
    append_line line + suffix
    lines.concat(text) unless text.empty?
    text
  end

  def format_append_text node, prefix="", suffix=""
    text = format_text node
    line = text.shift(1)[0].rstrip
    append_text prefix + line + suffix
    lines.concat(text) unless text.empty?
    text
  end

  def append_blank_line
    if @continuation
      @continuation = false
    elsif @adjoin_next
      @adjoin_next = false
    else
      @lines << ''
    end
  end
  alias :start_new_line :append_blank_line

  def append_block_title node, prefix = nil
    if (title_node = (node.at_css '> title') || (node.at_css '> info > title'))
      text = format_text title_node
      title = text.shift(1)[0];
      leading_char = '.'
      # special case for <itemizedlist role="see-also-list"><title>:
      # omit the prefix '.' as we want simple text on a bullet, not a heading
      if node.parent.name == 'itemizedlist' && ((node.attr 'role') == 'see-also-list')
        leading_char = nil
      end
      append_line %(#{leading_char}#{prefix}#{unwrap_text title})
      lines.concat text unless text.empty?
      @adjoin_next = true
      true
    else
      false
    end
  end

  def append_block_role node
    if (role = node.attr('role'))
      append_line %([.#{role}])
      #@adjoin_next = true
      true
    else
      false
    end
  end

  def append_text text, unsub = false
    text = reverse_subs text if unsub
    @lines[-1] = %(#{@lines[-1]}#{text})
  end

  ## Lifecycle callbacks

  def before_traverse node, method
    unless IGNORED_NAMES.include? node.name
      append_ifdef_start_if_condition(node)
    end

    case method.to_s
    when "visit_itemizedlist", "visit_orderedlist", 
         "visit_procedure", "visit_substeps", "visit_stepalternatives"
      @list_depth += 1
    when "visit_table", "visit_informaltable"
      @in_table = true
    when "visit_emphasis"
      marker = get_emphasis_quote_char node
      @nested_formatting.push marker
    when "process_literal"
      @nested_formatting.push '+'
    when "visit_subscript"
      @nested_formatting.push '~'
    when "visit_superscript"
      @nested_formatting.push '^'
    end
  end

  def after_traverse node, method
    method_name = method.to_s
    case method_name
    when "visit_book"
      if @requires_index && !@found_index
        append_index
      end
    when "visit_itemizedlist", "visit_orderedlist"
      @list_depth -= 1
    when "visit_table", "visit_informaltable"
      @in_table = false
    when "visit_emphasis", "process_literal"
      @nested_formatting.pop
    end

    @last_added_was_special = false
    case method_name
    when "visit_itemizedlist", "visit_orderedlist", "visit_table",
          "visit_informaltable", "visit_quandaset", "figure"
      @last_added_was_special = true
    end

    unless IGNORED_NAMES.include? node.name
      append_ifdef_end_if_condition(node)
    end
  end

  ## Node visitor callbacks

  def default_visit node
    warn %(No visitor defined for <#{node.name}>! Skipping.)
    node.to_xml.each_line do |line|
      append_line %(// #{line.chomp})
    end
    append_blank_line
    false
  end

  # pass thru XML entities unchanged, eg., for &rarr;
  def visit_entity_ref node
    case node.name
    when "nbsp"
      append_text "{nbsp}"
    when "wj"
      append_text "{wj}"
    when "true"
      append_text "`true`"
    when "false"
      append_text "`false`"
    else
      append_text %({#{node.name}})
    end
    false
  end

  def visit_comment node
    comment_lines = node.text.rstrip.split EOL
    if comment_lines.count > 1
      append_line '////'
      append_line (comment_lines * EOL)
      append_line '////'
    else
      append_line %(//#{node.text})
    end
    append_blank_line
    false
  end

  def ignore node
    false
  end
  # Skip title and subtitle as they're always handled by the parent visitor
  IGNORED_NAMES.each do |name|
    method_name = "visit_#{name}".to_sym
    alias_method method_name, :ignore
  end

  ### Document node (article | book | chapter) & header node (articleinfo | bookinfo | info) visitors

  def visit_book node
    process_doc node
  end

  def visit_article node
    process_doc node
  end

  def visit_info node
    if DOCUMENT_NAMES.include?(node.parent.name)
      process_info node
    elsif node == node.document.root
      process_included_info node
    end
  end
  alias :visit_bookinfo :visit_info
  alias :visit_articleinfo :visit_info

  def visit_chapter node
    # treat document with <chapter> root element as articles
    if node == node.document.root
      @adjoin_next = true
      process_section node do
        append_line ':compat-mode:' if @compat_mode
        append_line ':experimental:'
        append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
        append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
      end
    else
      process_section node
    end
  end

  def process_doc node
    append_line ':compat-mode:' if @compat_mode
    append_line ':doctype: book'
    append_line ':sectnums:'
    append_line ':toc:'
    append_line ':experimental:'
    append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
    append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
    @attributes.each do |name, val|
      append_line %(:#{name}: #{val}).rstrip
    end
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    false
  end

  def process_info node
    title = text_at_css node, '> title'
    append_line %(= #{title})
    authors = format_authors node
    append_line (authors * '; ') unless authors.empty?
    date_line = nil
    if (revnumber_node = node.at_css('revhistory revnumber', 'releaseinfo'))
      date_line = %(v#{revnumber_node.text}, ) 
    end
    if (date_node = node.at_css('> date', '> pubdate'))
      append_line %(#{date_line}#{date_node.text})
    end
    if node.name == 'bookinfo' || node.parent.name == 'book' || node.parent.name == 'chapter'
      append_line ':compat-mode:' if @compat_mode
      append_line ':doctype: book'
      append_line ':sectnums:'
      append_line ':toc:'
      append_line ':experimental:'
    end
    append_line %(:idprefix: #{@idprefix}).rstrip unless @idprefix == '_'
    append_line %(:idseparator: #{@idseparator}).rstrip unless @idseparator == '_'
    @attributes.each do |name, val|
      append_line %(:#{name}: #{val}).rstrip
    end
    false
  end

  def is_in_root_info node
    node.parent.name == 'info' && node.parent == node.document.root
  end

  def process_included_info node
    title = text_at_css node, '> title'
    append_line %(:title: #{title})

    if (subtitles = (format_text_at_css node, '> subtitle') )
      @lines += subtitles
        .reject { |line| line.empty? }
        .map { |line|
          line.start_with?("ifdef::") || line.start_with?("endif::") ? line : %(:subtitle: #{line})
        }
    end

    authors = format_authors node
    append_line %(:authors: #{authors * '; '}) unless authors.empty?

    revnumber = text(node.at_css('revhistory revnumber', 'releaseinfo')) || '1.0'
    append_line %(:revnumber: #{revnumber})
    
    if (date_node = node.at_css('> date', '> pubdate'))
      append_line %(:revdate: #{date_node.text})
    end

    if (abstract_node = (node.at_css '> abstract > para'))
      description = format_text abstract_node
      description = description.shift(1)[0]
      append_line %(:description: #{description}).rstrip
    end

    if (keywords_node = (node.at_css '> keywordset'))
      keywords = (keywords_node.css '> keyword').map { |keyword|
        text keyword
      }.join(', ')
      append_line %(:keywords: #{keywords}).rstrip
    end

    append_blank_line
    append_line '[colophon]'
    append_line %(#{'=' * @level} About This Book)
    
    @level += 1
    proceed node, :using_elements => true, :ignore_abstract => true
    @level -= 1

    append_blank_line
    false
  end

  # Very rough first pass at processing xi:include
  def visit_include node
    include_infile = node.attr 'href'
    converter = self.class.new include_infile, @opts
    converter.run

    @child_visitors << converter
    @ids_used_for_xrefs.merge(converter.ids_used_for_xrefs)

    append_blank_line
    include_outfile = converter.output_relative_to
    append_line %(:imagesdir: #{File.dirname(include_outfile)})
    append_line %(include::#{include_outfile}[leveloffset=+1])
    false
  end

  ### Section node visitors

  def visit_bridgehead node
    level = node.attr('renderas').nil? ? @level : node.attr('renderas').sub('sect', '').to_i + 1
    append_blank_line
    append_line '[float]'
    text = format_text node
    title = text.shift(1)[0];
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_line %(#{'=' * level} #{unwrap_text title})
    lines.concat text unless text.empty?
    false
  end

  def process_special_section node
    process_section node, node.name
  end

  def process_section node, special = nil
    return false if node.name == 'abstract' && is_in_root_info(node)

    append_blank_line
    if special
      append_line ':sectnums!:'
      append_blank_line
      append_line %([#{special}])
    end

    title_node = (node.at_css '> title') || (node.at_css '> info > title')
    title = if title_node
      if (subtitle_node = (node.at_css '> subtitle') || (node.at_css '> info > subtitle'))
        title_node.inner_html += %(: #{subtitle_node.inner_html})
      end
      text = format_text title_node
      text.shift(1)[0]
    else
      if special
        special.capitalize
      else
        warn %(No title found for section node: #{node})
        'Unknown Title!'
      end
    end
    if (id = (resolve_id node, normalize: @normalize_ids)) && id != (generate_id title)
      append_line %([[#{id}]])
    end
    append_ifdef_start_if_condition(title_node) if title_node
    append_line %(#{'=' * @level} #{unwrap_text title})
    lines.concat(text) unless text.nil? || text.empty?
    append_ifdef_end_if_condition(title_node) if title_node
    yield if block_given?
    if (abstract_node = (node.at_css '> info > abstract'))
      append_line
      append_line '[abstract]'
      append_line '--'
      abstract_node.elements.each do |el|
        append_line
        proceed el
        append_line
      end
      append_text '--'
    end
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    if special
      append_blank_line
      append_line ':sectnums:'
    end
    false
  end

  def generate_id title
    if title
      sep = @idseparator
      pre = @idprefix
      # FIXME move regexp to constant
      illegal_sectid_chars = /&(?:[[:alpha:]]+|#[[:digit:]]+|#x[[:alnum:]]+);|\W+?/
      id = %(#{pre}#{title.downcase.gsub(illegal_sectid_chars, sep).tr_s(sep, sep).chomp(sep)})
      if pre.empty? && id.start_with?(sep)
        id = id[1..-1]
        id = id[1..-1] while id.start_with?(sep)
      end
      id
    else
      nil
    end
  end

  def resolve_id node, opts = {}
    if (id = node['id'] || node['xml:id'])
      opts[:normalize] ? (normalize_id id) : id
    else
      nil
    end
  end

  # Lowercase id and replace underscores or hyphens with the @idseparator
  # TODO ensure id adheres to @idprefix
  def normalize_id id
    if id
      normalized_id = id.downcase.tr('_-', @idseparator)
      normalized_id = %(#{@idprefix}#{normalized_id}) if @idprefix && !(normalized_id.start_with? @idprefix)
      normalized_id
    else
      nil
    end
  end

  ### Part node visitors

  def visit_part node
    title_node = node.at_css '> title'
    title = if title_node
      text = format_text title_node
      text.shift(1)[0]
    else
      warn %(No title found for part node: #{node})
      'Unknown Title!'
    end

    append_blank_line
    append_line %(= #{title})
    proceed node
  end

  def visit_partintro node
    append_blank_line
    append_line '[partintro]'
    append_line '--'
    @level += 1
    proceed node, :using_elements => true
    @level -= 1
    append_line '--'
  end

  ### Block node visitors

  def visit_formalpara node
    append_blank_line
    append_block_title node
    true
  end

  def visit_para node
    empty_last_line = ! lines.empty? && lines.last.empty?
    append_blank_line
    @last_added_was_special = false
    append_block_role node
    append_blank_line unless empty_last_line
    true
  end

  def visit_simpara node
    empty_last_line = ! lines.empty? && lines.last.empty?
    append_blank_line
    append_block_role node
    append_blank_line unless empty_last_line
    true
  end

  def process_admonition node
    name = node.name
    label = name.upcase
    append_blank_line unless @continuation
    append_block_title node
    append_line %([#{label}])
    append_line '===='
    @adjoin_next = true
    proceed node
    @adjoin_next = false
    append_line '===='
    false
  end

  def visit_itemizedlist node
    append_blank_line
    append_block_title node
    append_blank_line if @list_depth == 1
    true
  end

  def visit_procedure node
    append_blank_line
    append_block_title node, 'Procedure: '
    visit_orderedlist node
  end

  def visit_substeps node
    visit_orderedlist node
  end

  def visit_stepalternatives node
    visit_orderedlist node
  end

  def visit_orderedlist node
    append_blank_line
    # TODO no title?
    if (numeration = (node.attr 'numeration')) && numeration != 'arabic'
      append_line %([#{numeration}])
    end
    append_blank_line if @list_depth == 1
    true
  end

  def visit_variablelist node
    append_blank_line
    append_block_title node
    @lines.pop if @lines[-1].empty?
    true
  end

  def visit_step node
    visit_listitem node
  end

  # FIXME this method needs cleanup, remove hardcoded logic!
  def visit_listitem node
    marker = (node.parent.name == 'orderedlist' || node.parent.name == 'procedure' ? '.' * @list_depth : 
      (node.parent.name == 'stepalternatives' ? 'a.' : '*' * @list_depth))
    append_text marker

    first_line = true
    unless node.elements.empty?

      only_text = true
      node.children.each do |child|
        if ! ( ( FORMATTING_NAMES.include? child.name ) || ( child.name.eql? "text" ) )
          only_text = false
          break
        end
      end

      if only_text
        text = format_text node
        item_text = text.shift(1)[0]

        item_text.split(EOL).each do |line|
          line = line.gsub IndentationRx, ''
          if line.length > 0
            if first_line
              append_text %( #{line})
            else
              append_line %(  #{line})
            end
          end
        end

        unless text.empty?
          append_line '+'
          lines.concat(text)
        end
      else
        node.children.each_with_index do |child,i|
          if ( child.name.eql? "text" ) && child.text.rstrip.empty?
            next
          end

          local_continuation = false
          unless i == 0 || first_line || (child.name == 'literallayout' || child.name == 'itemizedlist' || child.name == 'orderedlist')
            append_line '+'
            @continuation = true
            local_continuation = true
            first_line = true
          end

          if ( PARA_TAG_NAMES.include? child.name ) || ( child.name.eql? "text" )
            text = format_text child
            item_text = text.shift(1)[0]

            item_text = item_text.sub(/\A\+([^\n])/, "+\n\\1")
            if item_text.empty? && text.empty?
              next
            end

            item_text.split(EOL).each do |line|
              line = line.gsub IndentationRx, ''
              if line.length > 0
                if first_line
                  if local_continuation  # @continuation is reset by format_text
                    append_line %(#{line})
                  else
                    append_text %( #{line})
                  end
                else
                  append_line %(  #{line})
                end
              end
            end

            unless text.empty?
              append_line '+' unless lines.last == "+"
              lines.concat(text)
            end
          else
            if ! FORMATTING_NAMES.include? child.name
              if first_line && ! local_continuation
                append_text ' {empty}' # necessary to fool asciidoctorj into thinking that this is a listitem
              end
              unless local_continuation || (child.name == 'literallayout' || child.name == 'itemizedlist' || child.name == 'orderedlist')
                append_line '+'
              end
              @continuation = false
            end
            child.accept self
            @continuation = true
          end
          first_line = false
        end
      end
    else
      text = format_text node
      item_text = text.shift(1)[0]

      item_text.split(EOL).each do |line|
        line = line.gsub IndentationRx, ''
        if line.length > 0
          if first_line
            append_text %( #{line})
            first_line = false
          else
            append_line %(  #{line})
          end
        end
      end

      unless text.empty?
        append_line '+'
        lines.concat(text)
      end
    end
    @continuation = false
    append_blank_line unless lines.last.empty?

    false
  end

  def visit_varlistentry node
    # FIXME adds an extra blank line before first item
    #append_blank_line unless (previous = node.previous_element) && previous.name == 'title'
    append_blank_line
    
    text = format_text(node.at_css node, '> term')
    text.each do |text_line| 
      text_line.split(EOL).each_with_index do |line,i|
        line = line.gsub IndentationRx, ''
        if line.length > 0
          if i == 0 
            append_line line
          else 
            append_text ( " " + line )
          end
        end
      end
    end
    append_text "::"

    first_line = true
    listitem = node.at_css node, '> listitem'
    listitem.elements.each_with_index do |child,i|
      if ( child.name.eql? "text" ) && child.text.rstrip.empty?
        next
      end
    
      local_continuation = false
      unless i == 0 || first_line || (child.name == 'literallayout' || (LIST_NAMES.include? child.name) )
        append_line '+'
        append_blank_line
        @continuation = true
        local_continuation = true
      end
    
      if ( PARA_TAG_NAMES.include? child.name ) || ( child.name.eql? "text" )
        append_blank_line if i == 0

        text = format_text child
        item_text = text.shift(1)[0]
    
        item_text = item_text.sub(/\A\+([^\n])/, "+\n\\1")
        if item_text.empty? && text.empty?
          next
        end
    
        item_text.split(EOL).each do |line|
          line = line.gsub IndentationRx, ''
          if line.length > 0
            if first_line
              append_text line
              first_line = false
            else
              append_line line
            end
          end
        end
    
        unless text.empty?
          append_line '+' unless lines.last == "+"
          lines.concat(text)
        end
      else
        if ! FORMATTING_NAMES.include? child.name
          unless local_continuation || (child.name == 'literallayout' || (LIST_NAMES.include? child.name) )
            append_line '+'
          end
          @continuation = false
        end
        child.accept self
        @continuation = true
      end
    end

    false
  end

  def visit_glossentry node
    append_blank_line
    if !(previous = node.previous_element) || previous.name != 'glossentry'
      append_line '[glossary]'
    end
    true
  end

  def visit_glossterm node
    format_append_line node, "::"
    false
  end

  def visit_glossdef node
    append_line %(  #{text node.elements.first})
    false
  end

  def visit_citation node
    append_text %(<<#{node.text}>>)
  end

  def visit_bibliodiv node
    append_blank_line
    append_line '[bibliography]'
    true
  end

  def visit_bibliomisc node
    true
  end

  def visit_bibliomixed node
    append_blank_line
    append_text '- '
    node.children.each do |child|
      if child.name == 'abbrev'
        append_text %([[[#{child.text}]]] )
      elsif child.name == 'title'
        append_text child.text
      else
        child.accept self
      end
    end
    false
  end

  def visit_literallayout node
    append_blank_line
    source_lines = node.text.rstrip.split EOL
    if (source_lines.detect{|line| line.rstrip.empty?})
      append_line '....'
      append_line node.text.rstrip
      append_line '....'
    else
      source_lines.each do |line|
        append_line %(  #{line})
      end
    end
    false
  end

  def visit_screen node
    append_blank_line unless node.parent.name == 'para'
    source_lines = node.text.rstrip.split EOL
    if source_lines.detect {|line| line.match(/^-{4,}/) }
      append_line '[listing]'
      append_line '....'
      append_line node.text.rstrip
      append_line '....'
    else
      append_line '----'
      append_line format_listing(node.text)
      append_line '----'
    end
    false
  end

  def diff_from_bnr_programlisting node
    diff = ''
    hunks = [[]]

    def editorial_kind node_or_string
      return nil unless node_or_string.is_a? ::Nokogiri::XML::Node
      case node_or_string.name
      when 'new'
        :insert
      when 'del', 'rep'
        :delete
      when 'emphasis'
        node_or_string.attr('role') == 'strikethrough' ? :delete : :insert
      end  
    end

    def include_for_editorial? node, expected
      actual = editorial_kind(node)
      actual.nil? || actual == expected
    end

    def text_wrapping_shade node
      node.name == 'shd' ? %([shd]###{node.text}##) : node.text
    end

    def extract_text_from_hunk nodes_or_strings
      nodes_or_strings
        .map { |node| node.is_a?(String) ? node : text_wrapping_shade(node) }
        .join('')
        .gsub(/\n{2,}/, "\n\n")
    end
    
    def prefix_lines text, prefix
      text.each_line.map { |line|
        %(#{prefix}#{line})
      }.join()
    end
    
    visit_child = ->(child) {
      if !editorial_kind(child) && (text_to_include = text_wrapping_shade(child)) && (around_newline = text_to_include.partition("\n")) && around_newline[1] == "\n"
        hunks.last << %(#{around_newline[0]}#{around_newline[1]})
        hunks << []

        visit_child.(Nokogiri::XML::Text.new around_newline[2], child.document)
      else
        hunks.last << child
      end
    }

    for child in node.children
      visit_child.(child)
    end

    for hunk in hunks
      if hunk.all? { |node| editorial_kind(node).nil? }
        unmodified_text = extract_text_from_hunk(hunk)
        diff << prefix_lines(unmodified_text, ' ')
      else
        deletions = hunk.select { |node| include_for_editorial?(node, :delete) }
        deleted_text = extract_text_from_hunk(deletions)
        diff << prefix_lines(deleted_text, '-') unless deleted_text.strip.empty?

        insertions = hunk.select { |node| include_for_editorial?(node, :insert) }
        inserted_text = extract_text_from_hunk(insertions)
        diff << prefix_lines(inserted_text, '+') unless inserted_text.strip.empty?
      end
    end
    format_listing diff
  end

  def visit_programlisting node
    has_bnr_styles = !(node.at_css '> *').nil?
    language = (has_bnr_styles ? 'diff' : nil) || node.attr('language') || node.attr('role') || @attributes['source-language']
    language = %(,#{language.downcase}) if language
    linenums = node.attr('linenumbering') == 'numbered'
    append_blank_line unless node.parent.name == 'para'
    append_line %([source#{language}#{linenums ? ',linenums' : nil}])
    if (first_element = node.elements.first) && first_element.name == 'include'
      append_line '----'
      node.elements.each do |el|
        append_line %(include::{sourcedir}/#{el.attr 'href'}[])
      end
      append_line '----'
    elsif has_bnr_styles
      append_line '----'
      append_line diff_from_bnr_programlisting(node)
      append_line '----'
    else
      source_lines = node.text.rstrip.split EOL
      if @delimit_source || (source_lines.detect {|line| line.rstrip.empty?})
        append_line '----'
        append_line (source_lines * EOL)
        append_line '----'
      else
        append_line (source_lines * EOL)
      end
    end
    false
  end

  def visit_example node
    process_example node
  end

  def visit_informalexample node
    process_example node
  end

  def process_example node
    append_blank_line
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    append_block_title node
    elements = node.elements.to_a
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && (PARA_TAG_NAMES.include? (child = elements.first).name)
      append_line '[example]'
      # must reset adjoin_next in case block title is placed
      @adjoin_next = false
      format_append_line child
    else
      proceed node
    end
    false
  end

  # FIXME wrap this up in a process_block method
  def visit_sidebar node
    append_blank_line
    append_block_title node 
    elements = node.elements.to_a
    # TODO make skipping title a part of append_block_title perhaps?
    if elements.size > 0 && elements.first.name == 'title'
      elements.shift
    end
    if elements.size == 1 && PARA_TAG_NAMES.include?((child = elements.first).name)
      append_line '[sidebar]'
      format_append_line child
    else
      append_line '****'
      @adjoin_next = true
      proceed node
      @adjoin_next = false
      append_line '****'
    end
    false
  end

  def visit_blockquote node
    append_blank_line
    append_block_title node 
    
    attribution = (node.at_css '> attribution')
    attribution = %(, #{attribution.text.strip}) if attribution
    
    append_line %([quote#{attribution}])
    append_line '____'
    @adjoin_next = true
    proceed node
    @adjoin_next = false
    append_line '____'

    false
  end

  def visit_table node
    append_blank_line
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    append_block_title node
    process_table node
    false
  end

  def visit_informaltable node
    append_blank_line
    process_table node
    false
  end

  def process_table node
    numcols = (node.at_css '> tgroup').attr('cols').to_i
    unless (row_node = (node.at_css '> tgroup > thead > row')).nil?
      if (numheaders = row_node.elements.length) != numcols
        title = " \'" +
          ((title_node = (node.at_css '> title')).nil? ?
          "" : title_node.children[0].text) + "\'"
        warn %(#{numcols} columns specified in table#{title}, but only #{numheaders} headers)
      end
    end
    cols = ('1' * numcols).split('')
    body = node.at_css '> tgroup > tbody'
    unless body.nil?
      row1 = body.at_css '> row'
      row1_cells = row1.elements
      numcols.times do |i|
        next if (row1_cells[i].nil? || !(element = row1_cells[i].elements.first))
        case element.name
        when 'literallayout'
          cols[i] = %(#{cols[i]}*l)
        end
      end
    end

    if (frame = node.attr('frame'))
      frame = %(, frame="#{frame}")
    else
      frame = nil
    end
    options = []
    if (head = node.at_css '> tgroup > thead')
      options << 'header'
    end
    if (foot = node.at_css '> tgroup > tfoot')
      options << 'footer'
    end
    options = (options.empty? ? nil : %(, options="#{options * ','}"))
    append_line %([cols="#{cols * ','}"#{frame}#{options}])
    append_line '|==='
    if head
      (head.css '> row > entry').each do |cell|
        append_line %(| #{text cell})
      end
      append_blank_line
    end
    (node.css '> tgroup > tbody > row').each do |row|
      append_ifdef_start_if_condition(row)
      append_blank_line
      row.elements.each do |cell|
        case cell.name
        when 'literallayout'
          append_line %(|`#{text cell}`)
        else
          append_line '|'
          proceed cell
        end
      end
      append_ifdef_end_if_condition(row)
    end
    if foot
      (foot.css '> row > entry').each do |cell|
        # FIXME needs inline formatting like body
        append_line %(| #{text cell})
      end
    end
    append_line '|==='
    false
  end

  ### Inline node visitors

  def strip_whitespace text
    wsMatch = text.match(OnlyWhitespaceRx)
    if wsMatch != nil && wsMatch.size > 0
      return EmptyString
    end
    text.gsub(LeadingEndlinesRx, '')
      .gsub(WrappedIndentRx, @preserve_line_wrap ? EOL : ' ')
      .gsub(TrailingEndlinesRx, '')
  end

  def visit_text node
    in_para = PARA_TAG_NAMES.include?(node.parent.name) || node.parent.name == 'phrase' || node.parent.name == 'emphasis'
    # drop text if empty unless we're processing a paragraph
    unless node.text.rstrip.empty?
      text = node.text
      if in_para
        leading_space_match = text.match LeadingSpaceRx
        # strips surrounding endlines and indentation on normal paragraphs
        # TODO factor out this whitespace processing
        text = strip_whitespace text
        is_first = !node.previous_element && (!node.previous || node.previous.type != ENTITY_REF_NODE)
        if is_first
          text = text.lstrip
        elsif leading_space_match && !!(text !~ LeadingSpaceRx)
          if @lines[-1] == "----" || @lines[-1] == "====" 
            text = %(#{leading_space_match[0]}#{text})
          elsif (node_prev = node.previous) &&
                ! ( node_prev.name == "para" || node_prev.name == "text" ) &&
                ( (lines.last.end_with? " ") || (lines.last.end_with? "\n") || lines.last.empty? )
            # no leading space before text
          else
            text = %( #{text})
          end
        end

        # FIXME sentence-per-line logic should be applied at paragraph block level only
        if @sentence_per_line
          # FIXME move regexp to constant
          text = text.gsub(/(?:^|\b)\.[[:blank:]]+(?!\Z)/, %(.#{EOL}))
        end
      end
      # escape |'s in table cell text
      if @in_table
        text = text.gsub(/\|/, '\|')
      end
      if ! @nested_formatting.empty?
        if text.start_with? '_','*','+','`','#','^','~'
          text = '\\' + text
        end
      end
      if ( @lines[-1].empty? ) && ( text.start_with? '.' )
        text = text.sub( /\A(\.+)/, "$$\\1$$" )
      end
      readd_space = text.end_with? " ","\n"
      if @last_added_was_special
        text = "\n" + text.rstrip
      else
        text.rstrip!
      end
      text = text + " " if readd_space

      append_text text, true
    end
    false
  end

  def visit_anchor node
    return false if node.parent.name.start_with? 'biblio'
    id = resolve_id node, normalize: @normalize_ids
    append_text %([[#{id}]])
    false
  end

  def visit_email node
      address = node.text
      append_text %{mailto:#{address}[]}
  end

  def visit_link node
    if node.attr 'linkend'
      visit_xref node
    else
      visit_uri node
    end
    false
  end

  def visit_uri node
    url = if node.name == 'ulink'
      node.attr 'url'
    else
      href = (node.attribute_with_ns 'href', XlinkNs)
      if (href)
        href.value
      else
        node.text
      end
    end
    prefix = 'link:'
    if url.start_with?('http://') || url.start_with?('https://')
      prefix = nil
    end
    label = text node
    if label.empty? || url == label
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url})
    else
      if (ref = @attributes.key(url))
        url = %({#{ref}})
      end
      append_text %(#{prefix}#{url}[#{label}])
    end
    false
  end

  alias :visit_ulink :visit_uri

  # QUESTION detect bibliography reference and autogen label?
  def visit_xref node
    linkend = node.attr 'linkend'
    id = @normalize_ids ? (normalize_id linkend) : linkend
    @ids_used_for_xrefs << id
    text = format_text node
    label = text.shift(1)[0]
    if label.empty?
      append_text %(<<#{id}>>)
    else
      append_text %(<<#{id},#{lazy_quote label}>>)
    end
    lines.concat(text) unless text.empty?
    false
  end

  def visit_phrase node
    text = format_text node
    if element_with_condition?(node) && !text.empty? && !text.first.start_with?('\n')
      text.prepend('')
    end
    phText = text.shift(1)[0]
    if node.attr 'role'
      # FIXME for now, double up the marks to be sure we catch it
      append_text %([#{node.attr 'role'}]###{phText}##)
    else
      append_text %(#{phText})
    end
    lines.concat(text) unless text.empty?
    false
  end

  def visit_foreignphrase node
    format_append_text node
  end

  def visit_quote node
    format_append_text node, '"`', '`"'
  end

  def visit_emphasis node
    quote_char = get_emphasis_quote_char node
    times = (adjacent_character node) ? 2 : 1;

    format_append_text node, (quote_char * times), (quote_char * times)
    false
  end

  def get_emphasis_quote_char node
    roleAttr = node.attr('role')
    case roleAttr
    when 'strong', 'bold'
      '*'
    when 'marked', 'strikethrough'
      '#'
    else
      '_'
    end
  end

  def adjacent_character node
    if @nested_formatting.length > 1
      true
    elsif ((prev_node = node.previous) && prev_node.type == TEXT_NODE && PrevAdjacentChar =~ prev_node.text) ||
          ((next_node = node.next) && next_node.type == TEXT_NODE && NextAdjacentChar =~ next_node.text)
      true
    elsif (prev_node = node.previous) && ! prev_node.children.empty? && 
          ( FORMATTING_NAMES.include? prev_node.name ) &&
          (adj_child = prev_node.children[0]).type == TEXT_NODE && PrevAdjacentChar =~ adj_child.text
      true
    elsif (next_node = node.next) && (! next_node.children.empty? ) && 
          ( FORMATTING_NAMES.include? next_node.name ) &&
          (adj_child = next_node.children[0]).type == TEXT_NODE && NextAdjacentChar =~ adj_child.text
      true
    elsif (! lines.last.empty?) && (! lines.last.end_with? "\s","\n","\t","\f")
      true
    else
      false
    end
  end

  def visit_remark node
    append_blank_line
    format_append_text node, "//"
    false
  end

  def visit_trademark node
    format_append_text node, "#", "(TM)"
    false
  end

  def visit_prompt node
    # TODO remove the space left by the prompt
    #@lines.last.chop!
    false
  end

  def process_path node
    role = 'path'
    #role = case (name = node.name)
    #when 'directory'
    #  'path'
    #when 'filename'
    #  'path'
    #else
    #  name
    #end
    append_text %([#{role}]_#{node.text}_)
    false
  end

  def process_ui node
    name = node.name
    if name == 'guilabel' && (next_node = node.next) &&
        next_node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(next_node.name)
      name = 'guimenu'
    end

    case name
    # ex. <menuchoice><guimenu>System</guimenu><guisubmenu>Documentation</guisubmenu></menuchoice>
    when 'menuchoice'
      items = node.children.map {|n|
        if (n.type == ELEMENT_NODE) && ['guimenu', 'guisubmenu', 'guimenuitem'].include?(n.name)
          n.instance_variable_set :@skip, true
          n.text
        end
      }.compact
      append_text %(menu:#{items[0]}[#{items[1..-1] * ' > '}])
    # ex. <guimenu>Files</guimenu> (top-level)
    when 'guimenu'
      append_text %(menu:#{node.text}[])
      # QUESTION when is this needed??
      #items = []
      #while (node = node.next) && ((node.type == ENTITY_REF_NODE && ['rarr', 'gt'].include?(node.name)) ||
      #  (node.type == ELEMENT_NODE && ['guimenu', 'guilabel'].include?(node.name)))
      #  if node.type == ELEMENT_NODE
      #    items << node.text
      #  end
      #  node.instance_variable_set :@skip, true
      #end
      #append_text %([#{items * ' > '}]) 
    when 'guibutton'
      append_text %(btn:[#{node.text}])
    when 'keycap'
      append_text %(kbd:[#{node.text}])
    when 'application'
      append_text %([app]##{node.text}#)
    when 'guilabel', 'guimenuitem'
      append_text %(menu:#{node.text}[])
    end
    false
  end

  def process_keyword node
    role, char = case (name = node.name)
    when 'firstterm'
      ['term', '_']
    when 'citetitle'
      ['ref', '_']
    else
      [name, '#']
    end
    format_append_text node, %([#{role}]#{char}), char
    false
  end

  def process_literal node
    name = node.name
    unless ANONYMOUS_LITERAL_NAMES.include? name
      shortname = case name
      when 'envar'
        'var'
      when 'application'
        'app'
      else
        name.sub 'name', ''
      end
      append_text %([#{shortname}])
    end
  
    times = (adjacent_character node) ? 2 : 1;
    literal_char = ('`' * times)
    other_format_start = other_format_end = ''

    if @nested_formatting.length > 1 
      emphasis = false
      bold = false
      for i in 0..@nested_formatting.length-2
        case @nested_formatting[i]
        when '_'
          emphasis = true
        when '*'
          bold = true
        end
        if emphasis && bold
          break
        end
      end
  
      if emphasis && bold
        other_format_start = "**__"
        other_format_end = "__**"
      elsif emphasis
        other_format_start = other_format_end = "__"
      elsif bold
        other_format_start = other_format_end = "**"
      end
    end


    format_append_text node, literal_char + other_format_start, other_format_end + literal_char

    false 
  end

  def visit_inlinemediaobject node
    image_node = node.at_css('imageobject imagedata')
    src = image_node.attr('fileref')
    alt = text_at_css node, 'textobject phrase'
    generated_alt = ::File.basename(src)[0...-(::File.extname(src).length)]
    alt = nil if alt && alt == generated_alt
    append_text %(image:#{src}[#{lazy_quote alt}])
    false
  end

  def visit_mediaobject node
    visit_figure node
  end

  def visit_screenshot node
    visit_figure node
  end

  # FIXME share logic w/ visit_inlinemediaobject, which is the same here except no block_title and uses append_text, not append_line
  def visit_figure node
    return false if is_in_root_info(node)

    append_blank_line
    if (id = (resolve_id node, normalize: @normalize_ids))
      append_line %([[#{id}]])
    end
    append_block_title node
    if (image_node = node.at_css('imageobject imagedata'))
      src = image_node.attr('fileref')
      alt = text_at_css node, 'textobject phrase'
      generated_alt = ::File.basename(src)[0...-(::File.extname(src).length)]
      alt = nil if alt && alt == generated_alt
      width = if (width_value = image_node.attr('width'))
        %(pdfwidth="#{width_value}")
      end
      scale = if (scale_value = image_node.attr('scale'))
        %{scale="#{width_value}"}
      end
      attrs = [ lazy_quote(alt), width, scale ].compact
      append_blank_line
      append_line %(image::#{src}[#{attrs.join(',')}])
      append_blank_line
    else
      warn %(Unknown mediaobject <#{node.elements.first.name}>! Skipping.)
    end
    false
  end

  def visit_footnote node
    append_text %(footnote:[#{(text_at_css node, '> para', '> simpara').strip}])
    # FIXME not sure a blank line is always appropriate
    #append_blank_line
    false
  end

  def visit_funcsynopsis node
    append_blank_line unless node.parent.name == 'para'
    append_line '[source,c]'
    append_line '----'

    if (info = node.at_xpath 'db:funcsynopsisinfo', 'db': DocbookNs)
      info.text.strip.each_line do |line|
        append_line line.strip
      end
      append_blank_line
    end

    if (prototype = node.at_xpath 'db:funcprototype', 'db': DocbookNs)
      indent = 0
      first = true
      append_blank_line
      if (funcdef = prototype.at_xpath 'db:funcdef', 'db': DocbookNs)
        append_text funcdef.text
        indent = funcdef.text.length + 2
      end

      (prototype.xpath 'db:paramdef', 'db': DocbookNs).each do |paramdef|
        if first
          append_text ' ('
          first = false
        else
          append_text ','
          append_line ' ' * indent
        end
        append_text paramdef.text.sub(/\n.*/m, '')
        if (param = paramdef.at_xpath 'db:funcparams', 'db': DocbookNs)
          append_text %[ (#{param.text})]
        end
      end

      if (varargs = prototype.at_xpath 'db:varargs', 'db': DocbookNs)
        if first
          append_text ' ('
          first = false
        else
          append_text ','
          append_line ' ' * indent
        end
        append_text %(#{varargs.text}...)
      end

      append_text(first ? ' (void);' : ');')
    end

    append_line '----'
  end

  # FIXME blank lines showing up between adjacent index terms
  def visit_indexterm node
    previous_skipped = false
    if @skip.has_key? :indexterm
      skip_count = @skip[:indexterm]
      if skip_count > 0
        @skip[:indexterm] -= 1
        return false
      else
        @skip.delete :indexterm
        previous_skipped = true
      end
    end

    @requires_index = true
    entries = [(text_at_css node, 'primary'), (text_at_css node, 'secondary'), (text_at_css node, 'tertiary')].compact
    #if previous_skipped && (previous = node.previous_element) && previous.name == 'indexterm'
    #  append_blank_line
    #end
    @skip[:indexterm] = entries.size - 1 if entries.size > 1
    append_line %[(((#{entries * ','})))] unless entries.empty?
    # Only if next word matches the index term do we use double-bracket form
    #if entries.size == 1
    #  append_text %[((#{entries.first}))]
    #else
    #  @skip[:indexterm] = entries.size - 1
    #  append_text %[(((#{entries * ','})))]
    #end
    false
  end

  def visit_pi node
    case node.name
    when 'asciidoc-br'
      append_text ' +'
    when 'asciidoc-hr'
      # <?asciidoc-hr?> will be wrapped in a para/simpara
      append_text '\'' * 3
    end
    false
  end

  def visit_qandaset node
    node.elements.to_a.each do |quandadiv|
      quandadiv.elements.each do |element|
        if element.name == 'title'
          append_line ".#{element.text}"
          append_blank_line
          append_line '[qanda]'
        elsif element.name == 'qandaentry'
          id = resolve_id element, normalize: @normalize_ids
          if (question = element.at_xpath 'db:question/db:para', 'db': DocbookNs)
            append_line %([[#{id}]]) if id
            format_append_line question, "::"
            if (answer = element.at_xpath 'db:answer', 'db': DocbookNs)
              first = true
              answer.children.each_with_index do |child, i|
                unless child.text.rstrip.empty?
                  unless first
                    append_line '+'
                    @continuation = true
                  end
                  first = nil
                  child.accept self
                end
              end
              @continuation = false
            else
              warn %(Missing answer in quandaset!)
            end
            append_blank_line
          else
            warn %(Missing question in quandaset! Skipping.)
          end
        end
      end
    end
  end

  def lazy_quote text, seek = ','
    if text && (text.include? seek)
      %("#{text}")
    else
      text
    end
  end

  def unwrap_text text
    text.gsub WrappedIndentRx, ''
  end

  def element_with_condition? node
    node.type == ELEMENT_NODE && (node.attr('condition') || node.attr('audience') || node.attr('arch'))
  end

  def append_ifdef_if_condition node
    return unless element_with_condition?(node)
    condition = node.attr('condition') || node.attr('audience') || (if (arch = node.attr('arch'))
      "arch-#{arch}"
    end)
    yield condition
  end

  def append_ifdef_start_if_condition node
    append_ifdef_if_condition node do |condition|
      append_line "ifdef::#{condition}[]"
    end
  end

  def append_ifdef_end_if_condition node
    append_ifdef_if_condition node do |condition|
      append_line "endif::#{condition}[]"
      append_blank_line unless node.next && element_with_condition?(node.next)
    end
  end

  def replace_ifdef_lines
    out_lines = []
    @lines.each do |line|
      if (data = line.match(/^((ifdef|endif)::.+?\[\])(.+)$/))
        # data[1]: "(ifdef|endif)::something[]"
        out_lines << data[1]
        # data[3]: a string after "[]"
        out_lines << data[3]
      else
        out_lines << line
      end
    end
    @lines = out_lines
  end

  def rstrip_lines
    @lines.map! do |line|
      line.rstrip
    end
  end

  def drop_empty_lines
    @lines.shift while @lines.size > 0 && @lines.first.empty?
  end

  def remove_unused_ids
    id_line_regex = /^\[\[(\S+?)\]\]$/
    @lines.reject! { |line|
      (match = id_line_regex.match(line)) && (id = match[1]) && !@ids_used_for_xrefs.include?(id)
    }
  end

  def visit_superscript node
    format_append_text node, '^', '^'
    false
  end

  def visit_subscript node
    format_append_text node, '~', '~'
    false
  end

  def append_index
    append_blank_line
    append_line 'ifndef::backend-html5[]'
    append_line '[index]'
    append_line '== Index'
    append_line 'endif::backend-html5[]'  
  end

  def visit_index node
    @found_index = true
    append_index
  end

  def visit_date node
    return false unless is_in_root_info(node)
    append_blank_line
    append_line 'ifdef::revremark+revdate[Version {revnumber}, {revremark}, {revdate}]'
    append_line 'ifndef::revremark+revdate[Version {revnumber}, {docdate}]'
  end

  alias :visit_pubdate :visit_date

  def visit_copyright node
    return false unless is_in_root_info(node)
    append_blank_line
    holder = text_at_css node, 'holder'
    holder = %( by #{holder}) if holder
    append_line %(Copyright (C) {docyear}#{holder})
    false
  end

  def visit_address node
    text = format_text node
    address = text.shift(1)[0]
    @lines += address.each_line
      .map { |line|
        line.rstrip.empty? ? line : %(#{line.rstrip} +)
      }
    false
  end

  def visit_biblioid node
    return false unless is_in_root_info(node)
    text = format_text node
    text = text.shift(1)[0]
    kind = case (otherclass = node.attr('class'))
    when 'isbn10'
      "ISBN-10"
    when 'isbn13'
      "ISBN-13"
    else
      otherclass.upcase
    end
    append_line %(#{kind} #{text})
    false
  end

  CREDIT_TABLE = {
    'copyeditor' => 'copy-edited',
    'graphicdesigner' => 'graphics designed',
    'productioneditor' => 'production editing',
    'producer' => 'produced',
    'translator' => 'translated',
    'indexer' => 'indexed',
    'proofreader' => 'proof-read',
    'coverdesigner' => 'cover designed',
    'interiordesigner' => 'interior designed',
    'illustrator' => 'illustrations',
    'reviewer' => 'reviewed',
    'typesetter' => 'typeset'
  }

  def visit_othercredit node
    return false unless is_in_root_info(node)
    person = format_name node
    credit = ((kind = node.attr('class')) && CREDIT_TABLE[kind]) || 'edited'
    credit = credit.capitalize
    append_blank_line
    append_line %(#{credit} by #{person})
  end

  alias :visit_editor :visit_othercredit

  def default_output input
    File.join(File.dirname(input), %(#{File.basename(input, '.*')}.adoc))
  end

  def output_relative_to path = Dir.getwd
    ::Pathname.new(@output).relative_path_from(::Pathname.new(path))
  end
  
  def run
    input_dir = File.dirname(@input)
    Dir.chdir(input_dir) {
      xmldoc = File.open(@input) { |file|
        Nokogiri::XML(file) { |config|
          config.dtdload
        }
      }
      raise 'Not a parseable document' unless (root = xmldoc.root)
      root.accept self
    }
  end

  def finish
    after
    ::IO.write @output, (@lines * EOL)
    @child_visitors.each { |child|
      child.finish
    }
  end

end
end
