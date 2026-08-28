using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class Program
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    private static readonly string[] PayloadNames = new string[]
    {
        "DesktopIconTray.ps1",
        "DesktopIconManager.ps1",
        "Uninstall.ps1",
        "App.ico",
        "App-Hidden.ico",
        "Run-Hidden.vbs"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }

        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string tray = Path.Combine(dir, "DesktopIconTray.ps1");

        if (!File.Exists(tray))
        {
            dir = UnpackOrFail(args);
            if (dir == null) return 1;
            tray = Path.Combine(dir, "DesktopIconTray.ps1");
            if (!File.Exists(tray))
            {
                MessageBox.Show(
                    "DesktopIconTray.ps1 could not be unpacked. Download DesktopIconToggle-1.4.3.zip from GitHub Releases and run Install.bat.",
                    "Desktop Icon Toggle",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

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
            return StartHidden(powershell, "-NoProfile -ExecutionPolicy RemoteSigned -File \"" + uninstall + "\" -Silent", dir);
        }

        if (reset)
        {
            if (!File.Exists(manager)) return 1;
            return StartHidden(powershell, "-NoProfile -ExecutionPolicy RemoteSigned -File \"" + manager + "\" -Reset", dir);
        }

        string extra = showUi ? " -ShowUi" : "";
        return StartHidden(powershell, "-NoProfile -ExecutionPolicy RemoteSigned -File \"" + tray + "\"" + extra, dir);
    }

    private static string UnpackOrFail(string[] args)
    {
        if (!HasEmbeddedResource("DesktopIconTray.ps1"))
        {
            MessageBox.Show(
                "DesktopIconTray.ps1 was not found next to this program, and this copy of DesktopIconToggle.exe does not include the app files.\n\n" +
                "Download DesktopIconToggle-1.4.3.zip from GitHub Releases and run Install.bat:\n" +
                "https://github.com/nchrumka/desktop-icon-toggle/releases/latest",
                "Desktop Icon Toggle",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return null;
        }

        string installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DesktopIconToggle");
        ExtractPayload(installDir);

        string self = Assembly.GetExecutingAssembly().Location;
        string destExe = Path.Combine(installDir, "DesktopIconToggle.exe");
        bool alreadyThere = false;
        try
        {
            alreadyThere = string.Equals(Path.GetFullPath(self), Path.GetFullPath(destExe), StringComparison.OrdinalIgnoreCase);
        }
        catch { }

        if (!alreadyThere)
        {
            try { File.Copy(self, destExe, true); } catch { }
            if (File.Exists(destExe))
            {
                try
                {
                    ProcessStartInfo relaunch = new ProcessStartInfo();
                    relaunch.FileName = destExe;
                    relaunch.WorkingDirectory = installDir;
                    relaunch.UseShellExecute = false;
                    if (args != null && args.Length > 0)
                        relaunch.Arguments = string.Join(" ", args);
                    Process.Start(relaunch);
                    Environment.Exit(0);
                }
                catch { }
            }
        }

        return installDir;
    }

    private static bool HasEmbeddedResource(string name)
    {
        try
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream(name))
            {
                return s != null;
            }
        }
        catch
        {
            return false;
        }
    }

    private static void ExtractPayload(string destDir)
    {
        Directory.CreateDirectory(destDir);
        Assembly asm = Assembly.GetExecutingAssembly();
        foreach (string name in PayloadNames)
        {
            using (Stream s = asm.GetManifestResourceStream(name))
            {
                if (s == null) continue;
                string dest = Path.Combine(destDir, name);
                using (FileStream fs = File.Create(dest))
                {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0)
                        fs.Write(buf, 0, n);
                }
                try { File.Delete(dest + ":Zone.Identifier"); } catch { }
            }
        }
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