require_relative "errors"

module HTTP
  # The fields of a query string or of an application/x-www-form-urlencoded
  # body ("q=two+words&tag=a&tag=b"): "+" is a space and "%XX" a byte. A
  # field without "=" has the value ""; empty fields ("a=1&&b=2") are
  # skipped. A bad escape, or more than max_fields fields, raises
  # HTTP::BadRequest, so the client gets a 400.
  #
  #   params = HTTP::Params.new("page=2&tag=a&tag=b")
  #   params["page"]          # "2"   ("" when absent)
  #   params.int("page", 1)   # 2     (the default when absent or empty)
  #   params.all("tag")       # ["a", "b"]
  #
  # Parsing notes where each field lies in the source, which it keeps
  # without copying (so the source must not change while it is in use); a
  # value becomes a String (a new one, the app may keep it) only when
  # asked for, and #int reads its digits in place.
  class Params
    MAX_FIELDS = 1000
    MAX_DIGITS = 18

    def initialize(source = "", max_fields: MAX_FIELDS)
      @max_fields = max_fields
      @src = source
      # Per field: name from/to, value from/to (from == -1: no "="), and
      # whether the name / the value holds "+" or "%" (1) or not (0).
      @at = [0]
      @at.clear
      @coded = [0]
      @coded.clear
      parse(source)
    end

    # Replaces the fields with those of source, in one pass over it.
    def parse(source)
      @src = source
      @at.clear
      @coded.clear
      size = source.bytesize
      pos = 0
      while pos < size
        stop = pos
        eq = -1
        name_coded = 0
        value_coded = 0
        while stop < size
          b = source.getbyte(stop)
          break if b == 38
          if b == 61 && eq < 0
            eq = stop
          elsif b == 43 || b == 37
            if b == 37
              raise BadRequest, "bad %-escape" unless stop + 2 < size && hex(source.getbyte(stop + 1)) >= 0 && hex(source.getbyte(stop + 2)) >= 0
              stop += 2
            end
            if eq < 0
              name_coded = 1
            else
              value_coded = 1
            end
          end
          stop += 1
        end
        add(pos, eq, stop, name_coded, value_coded) if stop > pos
        pos = stop + 1
      end
      self
    end

    # The first value of name, "" when absent.
    def [](name)
      i = find(name.to_s)
      i < 0 ? "" : value(i)
    end

    def key?(name) = find(name.to_s) >= 0

    # Every value of name, in order.
    def all(name)
      name = name.to_s
      out = [""]
      out.clear
      i = 0
      while i < size
        out << value(i) if name?(i, name)
        i += 1
      end
      out
    end

    # The first value of name as an Integer: default when absent or empty,
    # HTTP::BadRequest when it is not one (or has more than 18 digits).
    def int(name, default)
      name = name.to_s
      i = find(name)
      return default.to_i if i < 0
      if @coded[i * 2 + 1] == 1
        v = value(i)
        return digits(v, 0, v.bytesize, name)
      end
      from = @at[i * 4 + 2]
      return default.to_i if from < 0 || from == @at[i * 4 + 3]
      digits(@src, from, @at[i * 4 + 3], name)
    end

    def each
      i = 0
      while i < size
        yield decode(@at[i * 4], @at[i * 4 + 1], @coded[i * 2]), value(i)
        i += 1
      end
      nil
    end

    def size = @at.size / 4
    def empty? = @at.empty?

    private

    def add(from, eq, stop, name_coded, value_coded)
      raise BadRequest, "more than #{@max_fields} fields" if size >= @max_fields
      if eq < 0
        @at << from << stop << -1 << -1
      else
        @at << from << eq << eq + 1 << stop
      end
      @coded << name_coded << value_coded
      nil
    end

    def find(name)
      i = 0
      while i < size
        return i if name?(i, name)
        i += 1
      end
      -1
    end

    # Whether field i is called name, comparing bytes in place when the
    # name needs no decoding.
    def name?(i, name)
      from = @at[i * 4]
      to = @at[i * 4 + 1]
      return decode(from, to, 1) == name if @coded[i * 2] == 1
      return false unless to - from == name.bytesize
      k = 0
      while k < name.bytesize
        return false unless @src.getbyte(from + k) == name.getbyte(k)
        k += 1
      end
      true
    end

    def value(i)
      from = @at[i * 4 + 2]
      return String.new if from < 0
      decode(from, @at[i * 4 + 3], @coded[i * 2 + 1])
    end

    # @src[from...to] in a new String, "+" and "%XX" decoded if coded.
    def decode(from, to, coded)
      out = @src.byteslice(from, to - from)
      return out if coded == 0
      n = out.bytesize
      r = 0
      w = 0
      while r < n
        b = out.getbyte(r)
        if b == 43
          b = 32
        elsif b == 37
          b = hex(out.getbyte(r + 1)) * 16 + hex(out.getbyte(r + 2))
          r += 2
        end
        out.setbyte(w, b)
        w += 1
        r += 1
      end
      w == n ? out : out.byteslice(0, w)
    end

    def digits(s, from, to, name)
      neg = s.getbyte(from) == 45
      i = neg ? from + 1 : from
      raise BadRequest, "#{name} is not an integer" if i == to || to - i > MAX_DIGITS
      n = 0
      while i < to
        b = s.getbyte(i)
        raise BadRequest, "#{name} is not an integer" if b < 48 || b > 57
        n = n * 10 + (b - 48)
        i += 1
      end
      neg ? -n : n
    end

    def hex(b) = Params.hex(b)

    # A path segment with its %XX escapes decoded ("+" stays a plus): the
    # value of a :param. A bad escape raises HTTP::BadRequest.
    def self.unescape(s)
      return s unless s.include?("%")
      out = s.dup
      n = out.bytesize
      r = 0
      w = 0
      while r < n
        b = out.getbyte(r)
        if b == 37
          raise BadRequest, "bad %-escape" unless r + 2 < n && hex(out.getbyte(r + 1)) >= 0 && hex(out.getbyte(r + 2)) >= 0
          b = hex(out.getbyte(r + 1)) * 16 + hex(out.getbyte(r + 2))
          r += 2
        end
        out.setbyte(w, b)
        w += 1
        r += 1
      end
      out.byteslice(0, w)
    end

    def self.hex(b)
      return b - 48 if b >= 48 && b <= 57
      return b - 55 if b >= 65 && b <= 70
      return b - 87 if b >= 97 && b <= 102
      -1
    end
  end
end
