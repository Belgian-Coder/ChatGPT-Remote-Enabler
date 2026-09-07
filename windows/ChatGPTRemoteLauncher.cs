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
[assembly: AssemblyVersion("1.5.53.0")]
[assembly: AssemblyFileVersion("1.5.53.0")]

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
            definition.Principal.LogonType = 3; // TASK_LOGON_INTERACTIVE_TOKEN
            definition.Principal.RunLevel = 0; // TASK_RUNLEVEL_LUA
            definition.Settings.Enabled = true;
            definition.Settings.Hidden = true;
            definition.Settings.AllowDemandStart = true;
            definition.Settings.DisallowStartIfOnBatteries = false;
            definition.Settings.StopIfGoingOnBatteries = false;
            definition.Settings.ExecutionTimeLimit = "PT0S";
            definition.Settings.MultipleInstances = 2; // TASK_INSTANCES_IGNORE_NEW
            dynamic action = definition.Actions.Create(0);
            string taskHost = Path.GetFullPath(Path.Combine(workingDirectory, @"CodexRemoteMobileProject\UpdateSessionTaskHost.exe"));
            if (!File.Exists(taskHost)) throw new FileNotFoundException("The GUI launch-worker task host was not found.");
            string encodedArguments = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(arguments));
            long expiresAtUnixMs = (long)(DateTime.UtcNow.AddSeconds(15) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            action.Path = taskHost;
            action.Arguments = "--worker " + QuoteArgument(executable) + " " + QuoteArgument(Path.Combine(workingDirectory, "Enable-ChatGPTRemote.ps1")) + " " + encodedArguments + " " + expiresAtUnixMs;
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

            string workerArguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + QuoteArgument(script) +
                    " -ParentProcessId " + current.Id +
                    " -ParentProcessStartTimeFileTimeUtc " + parentStartTimeFileTimeUtc +
                    " -ReadyEventName " + QuoteArgument(readyEventName) +
                    " -RejectedEventName " + QuoteArgument(rejectedEventName);
            try
            {
                using (Process child = StartSurvivingWorker(powershell, workerArguments, root))
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
