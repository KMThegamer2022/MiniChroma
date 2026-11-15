namespace MiniChroma.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // Show crashes in a message box, so a failure is visible instead of the app quietly disappearing.
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => ShowError(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => ShowError(e.ExceptionObject as Exception);
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "MiniChroma.Windows.SingleInstance", out bool first);
        if (!first) return;
        Application.Run(new TrayApp());
    }

    private static void ShowError(Exception? ex) =>
        MessageBox.Show("MiniChroma hit a problem:\n\n" + (ex?.Message ?? "unknown error"), "MiniChroma", MessageBoxButtons.OK, MessageBoxIcon.Error);
}
