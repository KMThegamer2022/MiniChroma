namespace MiniChroma.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "MiniChroma.Windows.SingleInstance", out bool first);
        if (!first) return;
        Application.Run(new TrayApp());
    }
}
