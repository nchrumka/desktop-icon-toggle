using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class Program
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }

        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string tray = Path.Combine(dir, "DesktopIconTray.ps1");
        string manager = Path.Combine(dir, "DesktopIconManager.ps1");
        string uninstall = Path.Combine(dir, "Uninstall.ps1");
        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");

        bool showUi = true;
        bool reset = false;
        bool uninstallApp = false;
        foreach (string a in args)
        {
            if (string.Equals(a, "-Tray", StringComparison.OrdinalIgnoreCase)) showUi = false;
            if (string.Equals(a, "-Reset", StringComparison.OrdinalIgnoreCase)) reset = true;
            if (string.Equals(a, "-Uninstall", StringComparison.OrdinalIgnoreCase)) uninstallApp = true;
        }

        if (uninstallApp)
        {
            DialogResult r = MessageBox.Show(
                "Remove Desktop Icon Toggle and restore any hidden desktop icons?",
                "Uninstall Desktop Icon Toggle",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return 0;
            if (!File.Exists(uninstall))
            {
                MessageBox.Show("Uninstall.ps1 was not found.", "Desktop Icon Toggle", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return StartHidden(powershell, "-NoProfile -ExecutionPolicy Bypass -File \"" + uninstall + "\" -Silent", dir);
        }

        if (reset)
        {
            if (!File.Exists(manager)) return 1;
            return StartHidden(powershell, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + manager + "\" -Reset", dir);
        }

        if (!File.Exists(tray))
        {
            MessageBox.Show("DesktopIconTray.ps1 was not found next to DesktopIconToggle.exe.", "Desktop Icon Toggle", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string extra = showUi ? " -ShowUi" : "";
        return StartHidden(powershell, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + tray + "\"" + extra, dir);
    }

    private static int StartHidden(string file, string arguments, string workDir)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = file;
        psi.Arguments = arguments;
        psi.WorkingDirectory = workDir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Desktop Icon Toggle", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
