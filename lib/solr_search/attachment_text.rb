# frozen_string_literal: true

module SolrSearch
  # The text of a Redmine attachment, or the reason there is none (design D-36, D-47). Only the files of the listed
  # extensions are sent to Tika (the plugin setting; the default is documents, text and PDF: no images, no archives); the
  # text is cut at a set length (about 3 MB), and a file too big is not sent at all. An attachment without text is still
  # indexed, by its file name and description.
  class AttachmentText
    # The extensions whose text is made when nothing else is set (design D-47): office files, text files (markup too), PDF.
    # No images (no text in them) and no archives: Tika opens an archive and joins what is inside into one text, with no way
    # to tell which file matched, huge, and whatever is inside goes into the index. Whoever accepts that adds them.
    DEFAULT_EXTENSIONS = %w[doc docx xls xlsx ppt pptx odt ods odp rtf
                            txt md csv tsv json xml html htm log yml yaml ini conf
                            pdf].freeze
    # The extensions that Tika opens as archives: said on the settings screen, when one of them is listed (design D-47)
    ARCHIVE_EXTENSIONS = %w[zip tar gz tgz bz2 xz 7z rar jar war cab iso].freeze
    MAX_FILE_BYTES = 50 * 1024 * 1024
    MAX_TEXT_BYTES = 3_000_000

    # status: :ok, :not_listed (its extension is not in the list), :too_large, :missing (the file is not on the disk), :unsupported, :unprocessable, :unavailable,
    # :error (anything else went wrong with this one file: it is indexed without text, like a damaged file)
    Result = Struct.new(:text, :status, :message, keyword_init: true) do
      def ok?
        status == :ok
      end
    end

    # extensions: the lower case extensions (no dot) whose text is made
    def initialize(tika:, extensions: DEFAULT_EXTENSIONS, max_file_bytes: MAX_FILE_BYTES, max_text_bytes: MAX_TEXT_BYTES)
      @tika = tika
      @extensions = extensions.map(&:to_s).map(&:downcase)
      @max_file_bytes = max_file_bytes
      @max_text_bytes = max_text_bytes
    end

    # attachment: filename, filesize, content_type, diskfile (Redmine's Attachment)
    def extract(attachment)
      return Result.new(status: :not_listed) unless listed?(attachment)
      return Result.new(status: :too_large) if attachment.filesize.to_i > @max_file_bytes

      path = attachment.diskfile
      return Result.new(status: :missing) unless File.file?(path.to_s)

      # a few bytes more than kept: truncate then cuts at a whole character
      text = @tika.text(path, filename: attachment.filename, content_type: attachment.content_type,
                              max_bytes: @max_text_bytes + 4)
      Result.new(text: self.class.truncate(text, @max_text_bytes), status: :ok)
    rescue TikaClient::Error => e
      Result.new(status: e.kind, message: e.message)
    rescue StandardError => e
      # one odd file must not stop the batch nor the run (M4 review, #4)
      Result.new(status: :error, message: "#{e.class}: #{e.message}".truncate(200))
    end

    # Whether the file's extension is one whose text is made: its last extension, in lower case (x.tar.gz is "gz"; a file
    # with no extension is never listed)
    def listed?(attachment)
      @extensions.include?(self.class.extension(attachment.filename))
    end

    def self.extension(filename)
      File.extname(filename.to_s).delete_prefix('.').downcase
    end

    # The list as the settings screen has it written (design D-47): separated by spaces, commas or line breaks, in any case,
    # with or without the dot. [the extensions that are valid, in the order written and each once; the pieces that were
    # left out because they are not an extension (only letters, digits, _, + and - are)].
    EXTENSION = /\A[a-z0-9_+-]+\z/

    def self.parse_extensions(text)
      pieces = text.to_s.downcase.split(/[\s,、;]+/).map {|piece| piece.delete_prefix('.') }.reject(&:empty?)
      valid, invalid = pieces.uniq.partition {|piece| EXTENSION.match?(piece) }
      [valid, invalid]
    end

    # At most this many bytes, without cutting a character in two
    def self.truncate(text, bytes)
      return text if text.bytesize <= bytes

      text.byteslice(0, bytes).scrub('')
    end
  end
end
