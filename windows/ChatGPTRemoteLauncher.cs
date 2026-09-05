using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("ChatGPT Remote Enabler")]
[assembly: AssemblyDescription("Starts ChatGPT with the remote access and Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Remote Enabler")]
[assembly: AssemblyVersion("1.5.35.0")]
[assembly: AssemblyFileVersion("1.5.35.0")]

internal static class ChatGPTRemoteLauncher
{
    private const int HandshakeTimeoutMilliseconds = 15000;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);

    private static int Fail(int code, string message)
    {
        MessageBox(IntPtr.Zero, message, "ChatGPT Remote Enabler", 0x10);
        return code;
    }

    private static string NewEventName(string suffix)
    {
        return @"Local\ChatGPTCustomLauncher-" + suffix + "-" + Guid.NewGuid().ToString("N");
    }

    private static string QuoteArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "Enable-ChatGPTRemote.ps1");
        if (!File.Exists(script))
        {
            Console.Error.WriteLine("Enable-ChatGPTRemote.ps1 was not found beside the launcher.");
            return Fail(2, "Enable-ChatGPTRemote.ps1 was not found beside the launcher.");
        }

        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powershell = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powershell))
        {
            Console.Error.WriteLine("Windows PowerShell was not found in the system directory.");
            return Fail(3, "Windows PowerShell was not found in the system directory.");
        }

        string readyEventName = NewEventName("Ready");
        string rejectedEventName = NewEventName("Rejected");
        using (var readyEvent = new EventWaitHandle(false, EventResetMode.ManualReset, readyEventName))
        using (var rejectedEvent = new EventWaitHandle(false, EventResetMode.ManualReset, rejectedEventName))
        {
            Process current = Process.GetCurrentProcess();
            long parentStartTimeFileTimeUtc = 0;
            try
            {
                parentStartTimeFileTimeUtc = current.StartTime.ToUniversalTime().ToFileTimeUtc();
            }
            catch
            {
                return Fail(6, "The launcher could not capture its process identity for the update handoff.");
            }

            var start = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + QuoteArgument(script) +
                    " -ParentProcessId " + current.Id +
                    " -ParentProcessStartTimeFileTimeUtc " + parentStartTimeFileTimeUtc +
                    " -ReadyEventName " + QuoteArgument(readyEventName) +
                    " -RejectedEventName " + QuoteArgument(rejectedEventName),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            // Windows PowerShell must build its own module path. Inheriting a
            // PowerShell 7 PSModulePath can hide the inbox hashing/DPAPI modules.
            start.EnvironmentVariables.Remove("PSModulePath");
            try
            {
                using (Process child = Process.Start(start))
                {
                    if (child == null) return Fail(4, "Windows PowerShell could not be started.");
                    int handshake = WaitForHandshake(readyEvent, rejectedEvent, child, HandshakeTimeoutMilliseconds);
                    if (handshake == 0) return 0;
                    if (handshake == 1)
                    {
                        child.WaitForExit(5000);
                        return Fail(15, "Another ChatGPT Remote Enabler launch is still running. Wait for it to finish, then try again.");
                    }
                    child.WaitForExit(5000);
                    return Fail(7, "ChatGPT Remote Enabler did not complete its startup handoff. See the local startup log for details.");
                }
            }
            catch
            {
                return Fail(5, "ChatGPT Remote Enabler failed before Windows PowerShell could complete.");
            }
        }
    }

    private static int WaitForHandshake(EventWaitHandle readyEvent, EventWaitHandle rejectedEvent, Process child, int timeoutMilliseconds)
    {
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < timeoutMilliseconds)
        {
            int remaining = timeoutMilliseconds - (int)timer.ElapsedMilliseconds;
            int index = WaitHandle.WaitAny(
                new WaitHandle[] { readyEvent, rejectedEvent },
                Math.Min(250, Math.Max(1, remaining)));
            if (index == 0) return 0;
            if (index == 1) return 1;
            if (child.HasExited) return -2;
        }
        try { if (!child.HasExited) child.Kill(); } catch { }
        return -1;
    }
}
