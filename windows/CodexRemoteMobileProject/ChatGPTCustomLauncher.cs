using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("ChatGPT Custom")]
[assembly: AssemblyDescription("Starts ChatGPT with the audited remote Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Custom")]
[assembly: AssemblyVersion("1.5.19.0")]
[assembly: AssemblyFileVersion("1.5.19.0")]

internal static class ChatGPTCustomLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string arg in args)
        {
            if (string.Equals(arg, expected, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static int Fail(int exitCode, bool silent, string message)
    {
        if (!silent) MessageBox(IntPtr.Zero, message, "ChatGPT Custom", 0x10);
        return exitCode;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool useProxy = HasArgument(args, "--proxy");
        bool startupMode = HasArgument(args, "--startup");
        foreach (string arg in args)
        {
            if (!string.Equals(arg, "--proxy", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(arg, "--startup", StringComparison.OrdinalIgnoreCase))
            {
                return Fail(13, startupMode, "The shortcut contains an unsupported launcher argument.");
            }
        }

        string root = AppDomain.CurrentDomain.BaseDirectory;
        string startupScript = Path.Combine(root, "MobileProjectStartup.ps1");
        if (!File.Exists(startupScript))
        {
            return Fail(11, startupMode, "MobileProjectStartup.ps1 was not found beside the launcher.");
        }

        bool created;
        int resultCode = 0;
        string failureMessage = null;
        using (var mutex = new Mutex(true, @"Local\ChatGPTCustomInjectionLauncher", out created))
        {
            if (!created)
            {
                resultCode = 15;
                failureMessage = "Another ChatGPT Custom launch is still running. Wait for it to finish, then try again.";
            }
            else
            {
                string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(executable))
                {
                    resultCode = 10;
                    failureMessage = "Windows PowerShell could not be found.";
                }
                else
                {
                    var start = new ProcessStartInfo
                    {
                        FileName = executable,
                        Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + startupScript +
                            "\" -Action Run" + (useProxy ? " -UseProxy" : "") + (startupMode ? "" : " -ReplaceRunningApp"),
                        WorkingDirectory = root,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WindowStyle = ProcessWindowStyle.Hidden
                    };

                    try
                    {
                        using (Process child = Process.Start(start))
                        {
                            if (child == null)
                            {
                                resultCode = 12;
                                failureMessage = "Windows PowerShell could not be started.";
                            }
                            else
                            {
                                child.WaitForExit();
                                if (child.ExitCode != 0)
                                {
                                    string log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                        @"CodexRemoteFeatures\startup.log");
                                    resultCode = child.ExitCode;
                                    failureMessage = "The injected launch could not be completed. If injection failed after ChatGPT was closed, ordinary ChatGPT was restored automatically.\r\n\r\nDetails: " + log;
                                }
                            }
                        }
                    }
                    catch
                    {
                        resultCode = 14;
                        failureMessage = "The injected launcher failed before Windows PowerShell could complete.";
                    }
                }
            }
        }
        return resultCode == 0 ? 0 : Fail(resultCode, startupMode, failureMessage);
    }
}
