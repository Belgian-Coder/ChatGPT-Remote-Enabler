using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("ChatGPT Custom")]
[assembly: AssemblyDescription("Starts ChatGPT with the audited remote Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Custom")]
[assembly: AssemblyVersion("1.1.0.0")]

internal static class ChatGPTCustomLauncher
{
    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string startup = Path.Combine(root, "MobileProjectStartup.ps1");
        if (!File.Exists(startup))
        {
            return 11;
        }

        bool created;
        using (var mutex = new Mutex(true, @"Local\ChatGPTCustomInjectionLauncher", out created))
        {
            if (!created)
            {
                return 0;
            }

            string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(executable))
            {
                return 10;
            }

            var start = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + startup + "\" -Action Run",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using (Process child = Process.Start(start))
            {
                if (child == null)
                {
                    return 12;
                }
                child.WaitForExit();
                return child.ExitCode;
            }
        }
    }
}
