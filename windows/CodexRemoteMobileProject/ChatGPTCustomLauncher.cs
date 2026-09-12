using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

[assembly: AssemblyTitle("ChatGPT Custom")]
[assembly: AssemblyDescription("Starts ChatGPT with the audited remote Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Custom")]
[assembly: AssemblyVersion("1.5.64.0")]
[assembly: AssemblyFileVersion("1.5.64.0")]

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

    private static bool IsLegacyVersionedRoot(string root)
    {
        string leaf = Path.GetFileName(root.TrimEnd(Path.DirectorySeparatorChar));
        return System.Text.RegularExpressions.Regex.IsMatch(leaf, @"^(?:ChatGPT-Remote-Enabler-Windows-x64|ChatGPTRemoteEnabler)(?:[-_]?v\d+\.\d+\.\d+)$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    }

    private static string GetStableRoot()
    {
        string commonData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        if (string.IsNullOrWhiteSpace(commonData)) return null;
        return Path.GetFullPath(Path.Combine(commonData, "CodexRemoteFeatures", "ChatGPT-Remote-Enabler-Windows-x64"));
    }

    private static bool HasNoReparsePointsThrough(string path, string stopAt)
    {
        string current = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        string stop = Path.GetFullPath(stopAt).TrimEnd(Path.DirectorySeparatorChar);
        while (true)
        {
            if (!File.Exists(current) && !Directory.Exists(current)) return false;
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return false;
            if (string.Equals(current, stop, StringComparison.OrdinalIgnoreCase)) return true;
            string parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) return false;
            current = parent.TrimEnd(Path.DirectorySeparatorChar);
        }
    }

    private static bool StableRootHasVerifiedEntryPoint(string root, string entryPoint)
    {
        try
        {
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            string commonData = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)).TrimEnd(Path.DirectorySeparatorChar);
            if (!root.StartsWith(commonData + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !HasNoReparsePointsThrough(root, commonData)) return false;
            string version = Path.Combine(root, "VERSION");
            string manifest = Path.Combine(root, "RELEASE-MANIFEST.sha256");
            string launcher = Path.Combine(root, entryPoint);
            if (!File.Exists(version) || !File.Exists(manifest) || !File.Exists(launcher) ||
                !HasNoReparsePointsThrough(version, root) || !HasNoReparsePointsThrough(manifest, root) || !HasNoReparsePointsThrough(launcher, root)) return false;
            string value = File.ReadAllText(version).Trim();
            if (!System.Text.RegularExpressions.Regex.IsMatch(value, @"^v\d+\.\d+\.\d+$")) return false;
            string expected = value.Substring(1) + ".0";
             bool versionHashVerified = false;
             bool launcherHashVerified = false;
             bool manifestHasEntries = false;
             var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
             foreach (string line in File.ReadAllLines(manifest))
             {
                 System.Text.RegularExpressions.Match match = System.Text.RegularExpressions.Regex.Match(line, @"^([0-9a-fA-F]{64}) \*(.+)$");
                 if (!match.Success) return false;
                  manifestHasEntries = true;
                  string relative = match.Groups[2].Value.Replace('/', Path.DirectorySeparatorChar);
                  if (Path.IsPathRooted(relative) || !seen.Add(relative)) return false;
                  string candidate = Path.GetFullPath(Path.Combine(root, relative));
                  if (!candidate.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) return false;
                  if (!File.Exists(candidate) || !HasNoReparsePointsThrough(candidate, root)) return false;
                 using (SHA256 algorithm = SHA256.Create())
                 using (FileStream stream = File.OpenRead(candidate))
                 {
                     string hash = BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "");
                     if (!string.Equals(hash, match.Groups[1].Value, StringComparison.OrdinalIgnoreCase)) return false;
                 }
                 if (string.Equals(candidate, version, StringComparison.OrdinalIgnoreCase)) versionHashVerified = true;
                 if (string.Equals(candidate, launcher, StringComparison.OrdinalIgnoreCase)) launcherHashVerified = true;
             }
             return manifestHasEntries && versionHashVerified && launcherHashVerified && string.Equals(FileVersionInfo.GetVersionInfo(launcher).FileVersion, expected, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private static int RedirectLegacyAlias(string root, string[] args)
    {
        if (!IsLegacyVersionedRoot(root)) return -1;
        string stableRoot = GetStableRoot();
        if (string.IsNullOrWhiteSpace(stableRoot) || string.Equals(Path.GetFullPath(root).TrimEnd('\\'), stableRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return -1;
        string entryPoint = Path.Combine("CodexRemoteMobileProject", "ChatGPT Custom.exe");
        if (!StableRootHasVerifiedEntryPoint(stableRoot, entryPoint)) return -1;
        string arguments = string.Join(" ", Array.ConvertAll(args, QuoteArgument));
        Process.Start(new ProcessStartInfo {
            FileName = Path.Combine(stableRoot, entryPoint), Arguments = arguments,
            WorkingDirectory = stableRoot, UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });
        return 0;
    }

    private static string PrepareDetachedTaskHost(string source)
    {
        string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData)) throw new InvalidOperationException("The per-user local application-data directory is unavailable.");
        string directory = Path.Combine(localApplicationData, "ChatGPTRemoteEnabler", "launch-hosts", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string destination = Path.Combine(directory, "UpdateSessionTaskHost.exe");
        try
        {
            File.Copy(source, destination, false);
            if (!string.Equals(Sha256File(source), Sha256File(destination), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The detached launch-worker copy failed hash verification.");
            return destination;
        }
        catch
        {
            try { if (File.Exists(destination)) File.Delete(destination); if (Directory.Exists(directory)) Directory.Delete(directory, true); } catch { }
            throw;
        }
    }

    private static string Sha256File(string path)
    {
        using (SHA256 algorithm = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
            return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    private static void TryDeleteDetachedHostDirectory(string directory)
    {
        try { if (Directory.Exists(directory)) Directory.Delete(directory, true); } catch { }
    }

    private static void PruneDetachedTaskHosts()
    {
        try
        {
            string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string root = Path.Combine(localApplicationData, "ChatGPTRemoteEnabler", "launch-hosts");
            if (!Directory.Exists(root)) return;
            foreach (string directory in Directory.GetDirectories(root))
            {
                var directoryInfo = new DirectoryInfo(directory);
                if (!System.Text.RegularExpressions.Regex.IsMatch(directoryInfo.Name, "^[0-9a-f]{32}$") ||
                    (directoryInfo.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(directory) < TimeSpan.FromMinutes(10)) continue;
                string executable = Path.Combine(directory, "UpdateSessionTaskHost.exe");
                bool referenced = false;
                bool inventoryComplete = true;
                foreach (Process process in Process.GetProcessesByName("UpdateSessionTaskHost"))
                {
                    try
                    {
                        string path = process.MainModule.FileName;
                        if (string.Equals(Path.GetFullPath(path), Path.GetFullPath(executable), StringComparison.OrdinalIgnoreCase)) referenced = true;
                    }
                    catch { inventoryComplete = false; }
                    finally { process.Dispose(); }
                }
                if (inventoryComplete && !referenced) TryDeleteDetachedHostDirectory(directory);
            }
        }
        catch { }
    }

    private static void ScheduleDetachedTaskHostCleanup(Process process, string executable)
    {
        try
        {
            string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string hostsRoot = Path.GetFullPath(Path.Combine(localApplicationData, "ChatGPTRemoteEnabler", "launch-hosts"));
            string directory = Path.GetFullPath(Path.GetDirectoryName(executable));
            if (!string.Equals(Path.GetDirectoryName(directory), hostsRoot, StringComparison.OrdinalIgnoreCase) ||
                !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(directory), "^[0-9a-f]{32}$")) return;
            string cleanup = Path.Combine(Path.GetDirectoryName(hostsRoot), "launch-host-cleanup-" + Guid.NewGuid().ToString("N") + ".ps1");
            string source =
                "param([int]$ProcessId,[long]$StartTimeFileTimeUtc,[string]$ExecutablePath,[string]$Directory)\r\n" +
                "$finished=$false;$deadline=[DateTime]::UtcNow.AddMinutes(10)\r\n" +
                "while([DateTime]::UtcNow -lt $deadline){try{$p=[Diagnostics.Process]::GetProcessById($ProcessId);try{$same=($p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $StartTimeFileTimeUtc) -and [string]::Equals([IO.Path]::GetFullPath($p.MainModule.FileName),[IO.Path]::GetFullPath($ExecutablePath),[StringComparison]::OrdinalIgnoreCase)}finally{$p.Dispose()};if(-not $same){$finished=$true;break}}catch{$finished=$true;break};Start-Sleep -Milliseconds 250}\r\n" +
                "if($finished){Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue\r\n";
            File.WriteAllText(cleanup, source, new System.Text.UTF8Encoding(false));
            string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            var start = new ProcessStartInfo {
                FileName = powerShell,
                Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + QuoteArgument(cleanup) +
                    " -ProcessId " + process.Id + " -StartTimeFileTimeUtc " + process.StartTime.ToUniversalTime().ToFileTimeUtc() +
                    " -ExecutablePath " + QuoteArgument(executable) + " -Directory " + QuoteArgument(directory),
                WorkingDirectory = Path.GetDirectoryName(cleanup), UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process cleanupProcess = Process.Start(start)) { }
        }
        catch { }
    }

    private static Process StartSurvivingWorker(string executable, string arguments, string workingDirectory)
    {
        PruneDetachedTaskHosts();
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
            string taskHostSource = Path.GetFullPath(Path.Combine(workingDirectory, "UpdateSessionTaskHost.exe"));
            if (!File.Exists(taskHostSource)) throw new FileNotFoundException("The GUI launch-worker task host was not found.");
            string taskHost = PrepareDetachedTaskHost(taskHostSource);
            string workerScript = Path.Combine(workingDirectory, "MobileProjectStartup.ps1");
            string packageRoot = Path.GetDirectoryName(workingDirectory.TrimEnd(Path.DirectorySeparatorChar));
            string encodedArguments = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(arguments));
            long expiresAtUnixMs = (long)(DateTime.UtcNow.AddSeconds(15) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            action.Path = taskHost;
            action.Arguments = "--worker " + QuoteArgument(executable) + " " + QuoteArgument(workerScript) + " " + encodedArguments + " " + expiresAtUnixMs +
                " " + Sha256File(workerScript) + " " + Sha256File(taskHostSource) + " " + QuoteArgument(packageRoot);
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
            ScheduleDetachedTaskHostCleanup(process, taskHost);
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
        int redirected = RedirectLegacyAlias(root, args);
        if (redirected >= 0) return redirected;
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
