using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("ChatGPT Custom")]
[assembly: AssemblyDescription("Starts ChatGPT with the audited remote Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Custom")]
[assembly: AssemblyVersion("1.5.6.0")]
[assembly: AssemblyFileVersion("1.5.6.0")]

internal static class ChatGPTCustomLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool useProxy = args.Length == 1 &&
            string.Equals(args[0], "--proxy", StringComparison.OrdinalIgnoreCase);
        if (args.Length > 1 || (args.Length == 1 && !useProxy))
        {
            return 13;
        }

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
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + startup +
                    "\" -Action Run" + (useProxy ? " -UseProxy" : ""),
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
