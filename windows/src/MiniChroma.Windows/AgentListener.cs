using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace MiniChroma.Windows;

/// Listens on 127.0.0.1:47800 for Claude agent states sent by the hook script. Loopback only.
public sealed class AgentListener : IDisposable
{
    private readonly object gate = new();
    private string status = "idle";
    private DateTime since = DateTime.UtcNow;
    private readonly UdpClient udp;

    public AgentListener()
    {
        udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 47800));
        _ = ReadLoopAsync();
    }

    public (string Status, double Seconds) Current()
    {
        lock (gate) return (status, (DateTime.UtcNow - since).TotalSeconds);
    }

    private async Task ReadLoopAsync()
    {
        while (true)
        {
            try
            {
                var result = await udp.ReceiveAsync();
                var json = JsonDocument.Parse(Encoding.UTF8.GetString(result.Buffer));
                if (json.RootElement.TryGetProperty("type", out var type) && type.GetString() == "agent"
                    && json.RootElement.TryGetProperty("status", out var value))
                {
                    lock (gate)
                    {
                        var next = value.GetString() ?? "idle";
                        if (next != status) { status = next; since = DateTime.UtcNow; }
                    }
                }
            }
            catch (ObjectDisposedException) { return; }
            catch { /* ignore malformed datagrams */ }
        }
    }

    public void Dispose() => udp.Dispose();
}
