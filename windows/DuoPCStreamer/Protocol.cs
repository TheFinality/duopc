using System.Buffers.Binary;

namespace DuoPCStreamer;

/// The DuoPC video stream, inside the gateway's TLS connection. Every message is
///   u8 type, u32 payload length (little-endian), payload.
/// Phone → PC:
///   Start        0x10  u32 bitrate kbps, u16 fps
///   PointerMove  0x11  i32 x, i32 y            (video pixels)
///   Button       0x12  u8 button (1 left, 2 middle, 3 right), u8 down
///   Scroll       0x13  i16 dx, i16 dy          (120 = one wheel notch)
///   Key          0x14  u32 X11 keysym, u8 down
///   Text         0x15  UTF-8                   (typed as Unicode)
///   SetBitrate   0x16  u32 kbps                (restarts the encoder)
/// PC → phone:
///   Config       0x01  u32 width, u32 height, u16 fps, u8 codec (1 = HEVC), hvcC record
///   Frame        0x02  u8 flags (1 = keyframe), u64 time µs, sample (length-prefixed NAL units)
///   Status       0x03  u8 code, UTF-8 message
///   Clipboard    0x04  UTF-8
public static class StreamProtocol
{
    public const byte Start = 0x10, PointerMove = 0x11, Button = 0x12, Scroll = 0x13, Key = 0x14, Text = 0x15, SetBitrate = 0x16;
    public const byte Config = 0x01, Frame = 0x02, Status = 0x03, Clipboard = 0x04;
    public const byte CodecHevc = 1;
    public const byte StatusCaptureUnavailable = 1, StatusEncoderFailed = 2;
    public const int MaxMessage = 64 * 1024 * 1024;

    public static async Task<(byte Type, byte[] Payload)?> ReadAsync(Stream stream, CancellationToken cancel)
    {
        var header = new byte[5];
        try { await stream.ReadExactlyAsync(header, cancel); }
        catch (EndOfStreamException) { return null; }
        var length = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(1));
        if (length < 0 || length > MaxMessage) throw new InvalidDataException($"message too long ({length})");
        var payload = new byte[length];
        await stream.ReadExactlyAsync(payload, cancel);
        return (header[0], payload);
    }

    public static byte[] Message(byte type, ReadOnlySpan<byte> payload)
    {
        var message = new byte[5 + payload.Length];
        message[0] = type;
        BinaryPrimitives.WriteInt32LittleEndian(message.AsSpan(1), payload.Length);
        payload.CopyTo(message.AsSpan(5));
        return message;
    }
}
