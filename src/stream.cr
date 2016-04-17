require "http/headers"
require "./data"

module HTTP2
  class Priority
    property exclusive : Bool
    property dep_stream_id : Int32
    property weight : Int32

    def initialize(@exclusive, @dep_stream_id, @weight)
    end

    def debug
      "exclusive=#{exclusive} dep_stream_id=#{dep_stream_id} weight=#{weight}"
    end
  end

  DEFAULT_PRIORITY = Priority.new(false, 0, 16)

  class Stream
    enum State
      IDLE
      RESERVED_LOCAL
      RESERVED_REMOTE
      OPEN
      HALF_CLOSED_LOCAL
      HALF_CLOSED_REMOTE
      CLOSED

      def to_s(io)
        case self
        when IDLE
          io << "idle"
        when RESERVED_LOCAL
          io << "reserved (local)"
        when RESERVED_REMOTE
          io << "reserved (remote)"
        when OPEN
          io << "open"
        when HALF_CLOSED_LOCAL
          io << "half-closed (local)"
        when HALF_CLOSED_REMOTE
          io << "half-closed (remote)"
        when CLOSED
          io << "closed"
        end
      end
    end

    getter id : Int32
    getter state : State
    property priority : Priority
    private getter connection : Connection

    def initialize(@connection, @id, @priority = DEFAULT_PRIORITY.dup, @state : State = State::IDLE)
    end

    def data
      @data ||= Data.new
    end

    def headers
      @headers ||= HTTP::Headers.new
    end

    def ==(other : Stream)
      id == other.id
    end

    def ==(other)
      false
    end

    def send_priority
      io = MemoryIO.new
      exclusive = priority.exclusive ? 0x80000000_u32 : 0_u32
      dep_stream_id = priority.dep_stream_id.to_u32 & 0x7fffffff_u32
      io.write_bytes(exclusive | dep_stream_id, IO::ByteFormat::BigEndian)
      io.write_byte((priority.weight - 1).to_u8)
      io.rewind
      connection.send Frame.new(Frame::Type::PRIORITY, self, 0, io.to_slice)
    end

    def send_headers(headers, flags = 0)
      payload = connection.hpack_encoder.encode(headers)
      send_headers(Frame::Type::HEADERS, headers, Frame::Flags.new(flags.to_u8), payload)
    end

    def send_push_promise(headers, flags = 0)
      return unless connection.remote_settings.enable_push

      connection.create_stream(state: Stream::State::RESERVED_LOCAL).tap do |stream|
        io = MemoryIO.new
        io.write_bytes(stream.id.to_u32 & 0x7fffffff_u32, IO::ByteFormat::BigEndian)
        payload = connection.hpack_encoder.encode(headers, writer: io)
        send_headers(Frame::Type::PUSH_PROMISE, headers, Frame::Flags.new(flags.to_u8), payload)
      end
    end

    protected def send_headers(type : Frame::Type, headers, flags, payload)
      max_frame_size = connection.remote_settings.max_frame_size

      if payload.size <= max_frame_size
        flags |= flags | Frame::Flags::END_HEADERS
        frame = Frame.new(type, self, flags, payload)
        connection.send(frame)
      else
        num = (payload.size / max_frame_size.to_f).ceil.to_i
        count = max_frame_size
        offset = 0

        frames = num.times.map do |index|
          type = Frame::Type::CONTINUATION if index > 1
          offset = index * max_frame_size
          if index == num
            count = payload.size - offset
            flags |= Frame::Flags::END_HEADERS
          end
          Frame.new(type, self, flags, payload[offset, count])
        end

        connection.send(frames.to_a)
      end
      nil
    end

    def send_data(data : String, flags = 0)
      send_data(data.to_slice, flags)
    end

    def send_data(data : Slice(UInt8), flags = 0)
      frame = Frame.new(Frame::Type::DATA, self, Frame::Flags.new(flags.to_u8))
      max_frame_size = connection.remote_settings.max_frame_size

      if data.size <= max_frame_size
        frame.payload = data
        connection.send(frame)
      else
        offset = 0
        while offset < data.size
          count = offset + max_frame_size > data.size ? data.size : max_frame_size
          frame.payload = data[offset, count]
          connection.send(frame)
          offset += count

          # OPTIMIZE: maybe we should sleep(0) here, in order to give other
          # coroutines a chance to send frames? so we can take advantage of
          # HTTP2 multiplexing? or maybe the Channel and IO are enough?
        end
      end
      nil
    end

    def receiving(frame : Frame)
      transition(frame, receiving: true)
    end

    def sending(frame : Frame)
      transition(frame, receiving: false)
    end

    # :nodoc:
    NON_TRANSITIONAL_FRAMES = [
      Frame::Type::PRIORITY,
      Frame::Type::GOAWAY,
      Frame::Type::PING,
      Frame::Type::WINDOW_UPDATE,
    ]

    private def transition(frame : Frame, receiving = false)
      return if frame.stream.id == 0 || NON_TRANSITIONAL_FRAMES.includes?(frame.type)

      case state
      when State::IDLE
        case frame.type
        when Frame::Type::HEADERS
          self.state = State::OPEN
        when Frame::Type::PUSH_PROMISE
          self.state = receiving ? State::RESERVED_REMOTE : State::RESERVED_LOCAL
        else
          error!(receiving)
        end

      when State::RESERVED_LOCAL
        error!(receiving) if receiving

        case frame.type
        when Frame::Type::HEADERS
          self.state = State::HALF_CLOSED_LOCAL
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        else
          error!(receiving)
        end

      when State::RESERVED_REMOTE
        error!(receiving) unless receiving

        case frame.type
        when Frame::Type::HEADERS
          self.state = State::HALF_CLOSED_REMOTE
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        else
          error!(receiving)
        end

      when State::OPEN
        case frame.type
        when Frame::Type::HEADERS, Frame::Type::DATA
          if frame.flags.end_stream?
            self.state = receiving ? State::HALF_CLOSED_REMOTE : State::HALF_CLOSED_LOCAL
          end
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        else
          error!(receiving)
        end

      when State::HALF_CLOSED_LOCAL, State::HALF_CLOSED_REMOTE
        if frame.flags.end_stream? || frame.type == Frame::Type::RST_STREAM
          self.state = State::CLOSED
        end

      when State::CLOSED
        case frame.type
        when Frame::Type::WINDOW_UPDATE, Frame::Type::RST_STREAM
          # ignore
        else
          error!(receiving)
        end
      end
    end

    private def error!(receiving = false)
      if receiving
        raise Error.protocol_error("STREAM #{id} is #{state}")
      else
        raise Error.internal_error("STREAM #{id} is #{state}")
      end
    end

    private def state=(@state)
      connection.logger.debug { "; Stream is now #{state}" }
    end
  end
end
