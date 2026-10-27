using System.Buffers.Binary;

namespace DuoPCStreamer;

/// The bits of HEVC bitstream handling the streamer needs: Annex B (start codes, as FFmpeg writes
/// it) to the length-prefixed form VideoToolbox decodes, and the hvcC record built from the
/// parameter sets.
public static class Hevc
{
    public const int Vps = 32, Sps = 33, Pps = 34;

    public static int NalType(ReadOnlySpan<byte> nal) => nal.Length > 0 ? (nal[0] >> 1) & 0x3F : -1;

    /// The NAL units in an Annex B buffer, without their start codes.
    public static List<ArraySegment<byte>> SplitAnnexB(byte[] data)
    {
        var nals = new List<ArraySegment<byte>>();
        int start = -1, i = 0;
        while (i + 3 <= data.Length)
        {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            {
                if (start >= 0) nals.Add(Trimmed(data, start, i));
                i += 3;
                start = i;
            }
            else i++;
        }
        if (start >= 0 && start < data.Length) nals.Add(Trimmed(data, start, data.Length));
        return nals;
    }

    /// A 4-byte start code's leading zero belongs to the next unit, not the end of this one.
    static ArraySegment<byte> Trimmed(byte[] data, int start, int end)
    {
        while (end > start && data[end - 1] == 0) end--;
        return new ArraySegment<byte>(data, start, end - start);
    }

    public static byte[] LengthPrefixed(IEnumerable<ArraySegment<byte>> nals)
    {
        var list = nals.ToList();
        var output = new byte[list.Sum(n => 4 + n.Count)];
        var offset = 0;
        foreach (var nal in list)
        {
            BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(offset), (uint)nal.Count);
            nal.AsSpan().CopyTo(output.AsSpan(offset + 4));
            offset += 4 + nal.Count;
        }
        return output;
    }

    public static bool IsKeyframe(IEnumerable<ArraySegment<byte>> nals) =>
        nals.Any(n => NalType(n) is >= 16 and <= 21);   // BLA, IDR, CRA

    /// The HEVCDecoderConfigurationRecord (ISO/IEC 14496-15) for these parameter sets, and the
    /// picture size from the SPS. Null if the SPS can't be read.
    public static (byte[] HvcC, int Width, int Height)? Config(byte[] vps, byte[] sps, byte[] pps)
    {
        try
        {
            var r = new BitReader(Unescape(sps.AsSpan(2)));   // past the 2-byte NAL header
            r.Skip(4);                                         // sps_video_parameter_set_id
            var maxSubLayersMinus1 = (int)r.Bits(3);
            var temporalIdNested = r.Bits(1);
            var generalStart = r.Position / 8;
            r.Skip(96);                                        // general profile, tier and level: 12 bytes
            var subProfile = new bool[maxSubLayersMinus1];
            var subLevel = new bool[maxSubLayersMinus1];
            for (var i = 0; i < maxSubLayersMinus1; i++) { subProfile[i] = r.Bits(1) == 1; subLevel[i] = r.Bits(1) == 1; }
            if (maxSubLayersMinus1 > 0) r.Skip(2 * (8 - maxSubLayersMinus1));
            for (var i = 0; i < maxSubLayersMinus1; i++) r.Skip((subProfile[i] ? 88 : 0) + (subLevel[i] ? 8 : 0));
            r.Ue();                                            // sps_seq_parameter_set_id
            var chroma = (int)r.Ue();
            if (chroma == 3) r.Skip(1);
            var width = (int)r.Ue();
            var height = (int)r.Ue();
            if (r.Bits(1) == 1)
            {
                int subWidth = chroma is 1 or 2 ? 2 : 1, subHeight = chroma == 1 ? 2 : 1;
                width -= subWidth * (int)(r.Ue() + r.Ue());
                height -= subHeight * (int)(r.Ue() + r.Ue());
            }
            var bitDepthLuma = (int)r.Ue();
            var bitDepthChroma = (int)r.Ue();

            var general = r.Data.AsSpan(generalStart, 12);
            var record = new List<byte> { 1 };
            record.AddRange(general.ToArray());                // profile space/tier/idc, compatibility, constraints, level
            record.AddRange([0xF0, 0x00]);                     // min_spatial_segmentation_idc 0
            record.Add(0xFC);                                  // parallelismType 0
            record.Add((byte)(0xFC | (chroma & 3)));
            record.Add((byte)(0xF8 | (bitDepthLuma & 7)));
            record.Add((byte)(0xF8 | (bitDepthChroma & 7)));
            record.AddRange([0, 0]);                           // avgFrameRate unknown
            record.Add((byte)(((maxSubLayersMinus1 + 1) << 3) | (int)(temporalIdNested << 2) | 3));   // 4-byte lengths
            record.Add(3);
            foreach (var (type, nal) in new[] { (Vps, vps), (Sps, sps), (Pps, pps) })
            {
                record.Add((byte)(0x80 | type));               // array_completeness
                record.AddRange([0, 1]);
                record.Add((byte)(nal.Length >> 8));
                record.Add((byte)nal.Length);
                record.AddRange(nal);
            }
            return (record.ToArray(), width, height);
        }
        catch (IndexOutOfRangeException)
        {
            return null;
        }
    }

    /// Drops emulation prevention bytes (00 00 03 → 00 00).
    static byte[] Unescape(ReadOnlySpan<byte> nal)
    {
        var output = new List<byte>(nal.Length);
        var zeros = 0;
        foreach (var b in nal)
        {
            if (zeros >= 2 && b == 3) { zeros = 0; continue; }
            output.Add(b);
            zeros = b == 0 ? zeros + 1 : 0;
        }
        return output.ToArray();
    }

    sealed class BitReader(byte[] data)
    {
        public byte[] Data { get; } = data;
        public int Position { get; private set; }

        public uint Bits(int count)
        {
            uint value = 0;
            for (var i = 0; i < count; i++, Position++)
                value = (value << 1) | (uint)((Data[Position / 8] >> (7 - Position % 8)) & 1);
            return value;
        }

        public void Skip(int count) => Position += count;

        /// Exp-Golomb.
        public uint Ue()
        {
            var zeros = 0;
            while (Bits(1) == 0) { if (++zeros > 31) throw new IndexOutOfRangeException(); }
            return (1u << zeros) - 1 + Bits(zeros);
        }
    }
}
