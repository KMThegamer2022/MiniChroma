namespace MiniChroma.Windows;

/// Entry point. The tray app, OpenRGB connection and effects are added in the next steps.
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new Form { Text = "MiniChroma (Windows, early build)", Width = 420, Height = 160 });
    }
}
