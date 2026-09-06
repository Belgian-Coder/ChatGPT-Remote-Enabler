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
[assembly: AssemblyVersion("1.5.46.0")]
[assembly: AssemblyFileVersion("1.5.46.0")]

internal static class ChatGPTCustomLauncher
{
    private const int HandshakeTimeoutMilliseconds = 15000;

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

    private static string NewEventName(string suffix)
    {
        return @"Local\ChatGPTCustomLauncher-" + suffix + "-" + Guid.NewGuid().ToString("N");
    }

    private static string QuoteArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static Process StartSurvivingWorker(string executable, string arguments, string workingDirectory)
    {
        object serviceObject = null;
        object rootObject = null;
        object definitionObject = null;
        object registeredObject = null;
        object runningObject = null;
        string taskName = "ChatGPTRemoteEnabler-LaunchWorker-" + Guid.NewGuid().ToString("N");
        try
        {
            Type schedulerType = Type.GetTypeFromProgID("Schedule.Service", true);
            serviceObject = Activator.CreateInstance(schedulerType);
            dynamic service = serviceObject;
            service.Connect();
            rootObject = service.GetFolder("\\");
            dynamic root = rootObject;
            definitionObject = service.NewTask(0);
            dynamic definition = definitionObject;
            definition.RegistrationInfo.Description = "Transient ChatGPT Remote launch worker.";
            definition.Principal.UserId = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
            definition.Principal.LogonType = 3;
            definition.Principal.RunLevel = 0;
            definition.Settings.Enabled = true;
            definition.Settings.Hidden = true;
            definition.Settings.AllowDemandStart = true;
            definition.Settings.DisallowStartIfOnBatteries = false;
            definition.Settings.StopIfGoingOnBatteries = false;
            definition.Settings.ExecutionTimeLimit = "PT0S";
            definition.Settings.MultipleInstances = 2;
            dynamic action = definition.Actions.Create(0);
            string taskHost = Path.GetFullPath(Path.Combine(workingDirectory, "UpdateSessionTaskHost.exe"));
            if (!File.Exists(taskHost)) throw new FileNotFoundException("The GUI launch-worker task host was not found.");
            string encodedArguments = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(arguments));
            long expiresAtUnixMs = (long)(DateTime.UtcNow.AddSeconds(15) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            action.Path = taskHost;
            action.Arguments = "--worker " + QuoteArgument(executable) + " " + QuoteArgument(Path.Combine(workingDirectory, "MobileProjectStartup.ps1")) + " " + encodedArguments + " " + expiresAtUnixMs;
            action.WorkingDirectory = workingDirectory;
            registeredObject = root.RegisterTaskDefinition(taskName, definition, 6, null, null, 3, null);
            dynamic registered = registeredObject;
            runningObject = registered.Run(null);
            dynamic running = runningObject;
            Stopwatch timer = Stopwatch.StartNew();
            int processId = 0;
            while (timer.ElapsedMilliseconds < 5000 && processId <= 0)
            {
                processId = (int)running.EnginePID;
                if (processId <= 0) Thread.Sleep(25);
            }
            if (processId <= 0) throw new InvalidOperationException("Task Scheduler did not report the launch worker process.");
            Process process = Process.GetProcessById(processId);
            string actualPath = Path.GetFullPath(process.MainModule.FileName);
            if (!string.Equals(actualPath, taskHost, StringComparison.OrdinalIgnoreCase))
            {
                process.Dispose();
                throw new InvalidOperationException("Task Scheduler started an unexpected launch worker executable.");
            }
            return process;
        }
        finally
        {
            if (rootObject != null)
            {
                try { ((dynamic)rootObject).DeleteTask(taskName, 0); } catch { }
            }
            foreach (object value in new object[] { runningObject, registeredObject, definitionObject, rootObject, serviceObject })
            {
                if (value != null && Marshal.IsComObject(value))
                {
                    try { Marshal.FinalReleaseComObject(value); } catch { }
                }
            }
        }
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

        int resultCode = 0;
        string failureMessage = null;
        string readyEventName = NewEventName("Ready");
        string rejectedEventName = NewEventName("Rejected");
        using (var readyEvent = new EventWaitHandle(false, EventResetMode.ManualReset, readyEventName))
        using (var rejectedEvent = new EventWaitHandle(false, EventResetMode.ManualReset, rejectedEventName))
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
                Process current = Process.GetCurrentProcess();
                long parentStartTimeFileTimeUtc = 0;
                try
                {
                    parentStartTimeFileTimeUtc = current.StartTime.ToUniversalTime().ToFileTimeUtc();
                }
                catch
                {
                    resultCode = 16;
                    failureMessage = "The launcher could not capture its process identity for the update handoff.";
                }
                if (resultCode == 0)
                {
                    string workerArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + QuoteArgument(startupScript) +
                            " -Action Run" + (useProxy ? " -UseProxy" : "") + (startupMode ? "" : " -ReplaceRunningApp") +
                            " -ParentProcessId " + current.Id +
                            " -ParentProcessStartTimeFileTimeUtc " + parentStartTimeFileTimeUtc +
                            " -ReadyEventName " + QuoteArgument(readyEventName) +
                            " -RejectedEventName " + QuoteArgument(rejectedEventName);

                    try
                    {
                        using (Process child = StartSurvivingWorker(executable, workerArguments, root))
                        {
                            if (child == null)
                            {
                                resultCode = 12;
                                failureMessage = "Windows PowerShell could not be started.";
                            }
                            else
                            {
                                int handshake = WaitForHandshake(readyEvent, rejectedEvent, child, HandshakeTimeoutMilliseconds);
                                if (handshake == 0)
                                {
                                    // The worker owns the mutex and waits for this exact process to
                                    // exit before it updates or launches anything. Returning here is
                                    // intentional: the old executable must be unlocked for replacement.
                                    resultCode = 0;
                                }
                                else if (handshake == 1)
                                {
                                    child.WaitForExit(5000);
                                    resultCode = 15;
                                    failureMessage = "Another ChatGPT Custom launch is still running. Wait for it to finish, then try again.";
                                }
                                else
                                {
                                    child.WaitForExit(5000);
                                    resultCode = 17;
                                    failureMessage = "The injected launch worker did not complete its startup handoff. See the local startup log for details.";
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
