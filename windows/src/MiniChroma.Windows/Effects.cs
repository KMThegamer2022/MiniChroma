namespace MiniChroma.Windows;

/// Colours for each effect. The maths matches the Mac app's StatusLighting rules.
public static class Effects
{
    public static (byte R, byte G, byte B) Compute(Settings settings, string agentStatus, double secondsInAgentState, double now)
    {
        var (r, g, b) = settings.Effect switch
        {
            "static" => (settings.Red / 255.0, settings.Green / 255.0, settings.Blue / 255.0),
            "agent" => Agent(AgentStatus(agentStatus, secondsInAgentState), now),
            _ => (0.0, 0.0, 0.0),
        };
        double k = Math.Clamp(settings.Brightness, 0, 1);
        return (ToByte(r * k), ToByte(g * k), ToByte(b * k));
    }

    /// Green stays for 30 seconds after Claude finishes, then the agent shows white.
    public static string AgentStatus(string status, double secondsInState) =>
        status == "done" && secondsInState >= 30 ? "idle" : status;

    private static (double R, double G, double B) Agent(string status, double now)
    {
        double Pulse(double hz) => 0.5 + 0.5 * Math.Sin(now * 2 * Math.PI * hz);
        (double R, double G, double B) Mix(double r, double g, double b, double amount) =>
            (r * (1 - amount), g * (1 - amount), b * (1 - amount));
        return status switch
        {
            "thinking" => Mix(1, 0.5, 0, 0.6 * (1 - Pulse(0.5))),
            "editing" => Mix(0.6, 0.2, 1, 0.6 * (1 - Pulse(0.5))),
            "done" => (0, 0.9, 0.2),
            "needs_input" => Mix(0.1, 0.3, 1, 0.7 * (1 - Pulse(2.5))),
            _ => (1, 1, 1),
        };
    }

    private static byte ToByte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
}
