using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
internal static class SetupLauncher {
    [STAThread] static void Main() {
        try {
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Setup-ChatGPTRemote.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Keep Setup with the complete Remote Enabler package.");
            Process.Start(new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + script + "\"",
                UseShellExecute = false, CreateNoWindow = true,
                WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory
            });
        } catch (Exception error) { MessageBox.Show(error.Message, "Remote Enabler setup", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
