using System;
using System.Diagnostics;
using System.IO;

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

        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = false
        };
        Process.Start(start);
        return 0;
    }
}
