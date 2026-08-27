using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("ChatGPT Remote Enabler")]
[assembly: AssemblyDescription("Starts ChatGPT with the remote access and Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Remote Enabler")]
[assembly: AssemblyVersion("1.5.9.0")]
[assembly: AssemblyFileVersion("1.5.9.0")]

internal static class ChatGPTRemoteLauncher
{
    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "Enable-ChatGPTRemote.ps1");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Enable-ChatGPTRemote.ps1 was not found beside the launcher.");
            return 2;
        }

        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powershell = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powershell))
        {
            Console.Error.WriteLine("Windows PowerShell was not found in the system directory.");
            return 3;
        }

        var start = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        try
        {
            using (Process child = Process.Start(start))
            {
                if (child == null) return 4;
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch
        {
            return 5;
        }
    }
}
