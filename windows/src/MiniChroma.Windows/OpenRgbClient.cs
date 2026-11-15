using System.Net.Sockets;
using System.Text;

namespace MiniChroma.Windows;

/// Talks to OpenRGB's SDK server (default 127.0.0.1:6742) to set device colours.
/// Packet layout follows OpenRGB's NetworkProtocol.h: "ORGB" magic, device index, packet id and size, all little-endian.
public sealed class OpenRgbClient : IDisposable
{
    private const uint Magic = 0x42524F47; // bytes "ORGB" read as little-endian
    private const uint PacketRequestControllerCount = 0;
    private const uint PacketRequestControllerData = 1;
    private const uint PacketRequestProtocolVersion = 40;
    private const uint PacketSetClientName = 50;
    private const uint PacketUpdateLeds = 1050;
    private const uint PacketSetCustomMode = 1100;
    private const uint ClientProtocolVersion = 4;

    private TcpClient? client;
    private NetworkStream? stream;
    private uint protocolVersion;

    public bool IsConnected => client?.Connected == true;

    public async Task ConnectAsync(string host, int port)
    {
        Close();
        client = new TcpClient { NoDelay = true };
        await client.ConnectAsync(host, port);
        stream = client.GetStream();
        await SendAsync(0, PacketSetClientName, Encoding.UTF8.GetBytes("MiniChroma"));
        await SendAsync(0, PacketRequestProtocolVersion, BitConverter.GetBytes(ClientProtocolVersion));
        var reply = await ReceiveAsync();
        protocolVersion = reply.Payload.Length >= 4 ? BitConverter.ToUInt32(reply.Payload, 0) : 0;
    }

    public async Task<int> ControllerCountAsync()
    {
        await SendAsync(0, PacketRequestControllerCount, Array.Empty<byte>());
        var reply = await ReceiveAsync();
        return reply.Payload.Length >= 4 ? (int)BitConverter.ToUInt32(reply.Payload, 0) : 0;
    }

    public async Task<DeviceInfo> ControllerDataAsync(int index)
    {
        await SendAsync((uint)index, PacketRequestControllerData, BitConverter.GetBytes(ClientProtocolVersion));
        var reply = await ReceiveAsync();
        return DeviceInfo.Parse(reply.Payload, index, protocolVersion);
    }

    public Task SetCustomModeAsync(int device) => SendAsync((uint)device, PacketSetCustomMode, Array.Empty<byte>());

    /// Sends one colour per LED. Each colour is 4 bytes: red, green, blue, and an unused byte.
    public Task UpdateLedsAsync(int device, IReadOnlyList<(byte R, byte G, byte B)> colours)
    {
        var body = new List<byte>();
        body.AddRange(BitConverter.GetBytes((ushort)colours.Count));
        foreach (var c in colours) { body.Add(c.R); body.Add(c.G); body.Add(c.B); body.Add(0); }
        var payload = new List<byte>();
        payload.AddRange(BitConverter.GetBytes((uint)(body.Count + 4)));
        payload.AddRange(body);
        return SendAsync((uint)device, PacketUpdateLeds, payload.ToArray());
    }

    private async Task SendAsync(uint device, uint packetId, byte[] payload)
    {
        if (stream is null) throw new InvalidOperationException("Not connected to OpenRGB");
        var header = new List<byte>();
        header.AddRange(BitConverter.GetBytes(Magic));
        header.AddRange(BitConverter.GetBytes(device));
        header.AddRange(BitConverter.GetBytes(packetId));
        header.AddRange(BitConverter.GetBytes((uint)payload.Length));
        await stream.WriteAsync(header.ToArray());
        if (payload.Length > 0) await stream.WriteAsync(payload);
    }

    private sealed record Packet(uint Device, uint Id, byte[] Payload);

    private async Task<Packet> ReceiveAsync()
    {
        if (stream is null) throw new InvalidOperationException("Not connected to OpenRGB");
        var header = await ReadExactAsync(16);
        if (BitConverter.ToUInt32(header, 0) != Magic) throw new InvalidDataException("OpenRGB sent an unexpected packet");
        uint device = BitConverter.ToUInt32(header, 4);
        uint id = BitConverter.ToUInt32(header, 8);
        uint size = BitConverter.ToUInt32(header, 12);
        var payload = size > 0 ? await ReadExactAsync((int)size) : Array.Empty<byte>();
        return new Packet(device, id, payload);
    }

    private async Task<byte[]> ReadExactAsync(int count)
    {
        var buffer = new byte[count];
        int read = 0;
        while (read < count)
        {
            int n = await stream!.ReadAsync(buffer.AsMemory(read, count - read));
            if (n == 0) throw new IOException("OpenRGB closed the connection");
            read += n;
        }
        return buffer;
    }

    public void Close()
    {
        stream?.Dispose();
        client?.Dispose();
        stream = null;
        client = null;
    }

    public void Dispose() => Close();
}

/// The parts of an OpenRGB device description that MiniChroma needs: its name and how many LEDs it has.
public sealed record DeviceInfo(int Index, string Name, int LedCount)
{
    /// Reads the device description. The fields follow OpenRGB's serialised layout; the LED count is read
    /// from the LED list at the end. A mismatch throws, so a wrong read never sends the wrong number of colours.
    public static DeviceInfo Parse(byte[] data, int index, uint protocol)
    {
        var reader = new PayloadReader(data);
        reader.U32(); // total size
        reader.I32(); // device type
        string name = reader.String();
        if (protocol >= 1) reader.String(); // vendor
        reader.String(); // description
        reader.String(); // version
        reader.String(); // serial
        reader.String(); // location

        int modes = reader.U16();
        reader.I32(); // active mode
        for (int m = 0; m < modes; m++) reader.SkipMode(protocol);

        int zones = reader.U16();
        for (int z = 0; z < zones; z++) reader.SkipZone(protocol);

        int leds = reader.U16();
        for (int l = 0; l < leds; l++) { reader.String(); reader.U32(); }

        int colours = reader.U16();
        if (colours != leds) throw new InvalidDataException($"{name}: device layout did not match (LEDs {leds}, colours {colours})");
        return new DeviceInfo(index, name, leds);
    }

    private sealed class PayloadReader(byte[] data)
    {
        private int position;

        public uint U32() { var v = BitConverter.ToUInt32(data, position); position += 4; return v; }
        public int I32() { var v = BitConverter.ToInt32(data, position); position += 4; return v; }
        public ushort U16() { var v = BitConverter.ToUInt16(data, position); position += 2; return v; }
        public string String()
        {
            // Strings are a 16-bit length (including the terminating zero) followed by the bytes.
            int length = U16();
            var text = Encoding.UTF8.GetString(data, position, Math.Max(0, length - 1));
            position += length;
            return text;
        }
        public void Skip(int bytes) => position += bytes;

        public void SkipMode(uint protocol)
        {
            String();
            I32();                       // value
            U32();                       // flags
            U32(); U32();                // speed min/max
            if (protocol >= 3) { U32(); U32(); } // brightness min/max
            U32(); U32();                // colour min/max
            U32(); U32(); U32();         // speed, direction, colour mode (brightness handled above when present)
            if (protocol >= 3) U32();    // brightness
            int colours = U16();
            Skip(colours * 4);
        }

        public void SkipZone(uint protocol)
        {
            String();
            I32();                       // zone type
            U32(); U32(); U32();         // leds min, max, count
            int matrixLength = U16();
            Skip(matrixLength);          // matrix block (kept as raw bytes)
            int segments = U16();
            for (int s = 0; s < segments; s++) { String(); I32(); U32(); U32(); }
            if (protocol >= 4) U32();    // zone flags
        }
    }
}
