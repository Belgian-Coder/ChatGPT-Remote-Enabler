using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;

internal static class UpdateSessionTaskHost
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private static string FullPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.IndexOfAny(new[] { '\0', '\r', '\n', '"' }) >= 0)
            throw new ArgumentException("An update-session task-host value is invalid.");
        return Path.GetFullPath(value);
    }

    private static string Sha256File(string file)
    {
        using (var stream = File.OpenRead(file))
        using (var algorithm = SHA256.Create())
        {
            var text = new StringBuilder(64);
            foreach (byte value in algorithm.ComputeHash(stream)) text.Append(value.ToString("x2"));
            return text.ToString();
        }
    }

    private static string QuoteArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static bool IsDirectChild(string parent, string child)
    {
        return string.Equals(Path.GetDirectoryName(child), parent, StringComparison.OrdinalIgnoreCase);
    }

    private static void UseStableUserTemporaryDirectory(ProcessStartInfo start)
    {
        string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
            throw new InvalidOperationException("The per-user local application-data directory is unavailable.");
        string temporaryDirectory = Path.GetFullPath(Path.Combine(localApplicationData, "Temp"));
        Directory.CreateDirectory(temporaryDirectory);
        start.EnvironmentVariables["TEMP"] = temporaryDirectory;
        start.EnvironmentVariables["TMP"] = temporaryDirectory;
    }

    private static string ProcessImagePath(Process process)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        do
        {
            var path = new StringBuilder(32768);
            uint size = (uint)path.Capacity;
            if (QueryFullProcessImageName(process.Handle, 0, path, ref size)) return Path.GetFullPath(path.ToString());
            if (process.HasExited) break;
            System.Threading.Thread.Sleep(25);
        } while (DateTime.UtcNow < deadline);
        return null;
    }

    private static void AssertNoReparseThrough(string path, string stopAt)
    {
        string current = path;
        string stop = stopAt.TrimEnd(Path.DirectorySeparatorChar);
        while (true)
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("An update-session path traverses a reparse point.");
            if (string.Equals(current.TrimEnd(Path.DirectorySeparatorChar), stop, StringComparison.OrdinalIgnoreCase)) return;
            string parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("An update-session path escaped its root.");
            current = parent;
        }
    }

    private static int RunWorker(string[] args)
    {
        if (args.Length != 8 || !string.Equals(args[0], "--worker", StringComparison.Ordinal)) return 20;
        string powershell = FullPath(args[1]);
        string script = FullPath(args[2]);
        string packageRoot = FullPath(args[7]);
        string expectedMobile = Path.GetFullPath(Path.Combine(packageRoot, @"CodexRemoteMobileProject\MobileProjectStartup.ps1"));
        string expectedRoot = Path.GetFullPath(Path.Combine(packageRoot, "Enable-ChatGPTRemote.ps1"));
        bool allowed = string.Equals(script, expectedMobile, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(script, expectedRoot, StringComparison.OrdinalIgnoreCase);
        string expectedPowerShell = FullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"));
        long expiresAtUnixMs;
        long nowUnixMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        if (!long.TryParse(args[4], out expiresAtUnixMs) || expiresAtUnixMs < nowUnixMs || expiresAtUnixMs > nowUnixMs + 30000) return 21;
        if (!allowed || !string.Equals(powershell, expectedPowerShell, StringComparison.OrdinalIgnoreCase) ||
            !System.Text.RegularExpressions.Regex.IsMatch(args[3], "^[A-Za-z0-9+/]+={0,2}$") ||
            !System.Text.RegularExpressions.Regex.IsMatch(args[5], "^[a-fA-F0-9]{64}$") ||
            !System.Text.RegularExpressions.Regex.IsMatch(args[6], "^[a-fA-F0-9]{64}$")) return 21;
        AssertNoReparseThrough(script, packageRoot);
        AssertNoReparseThrough(packageRoot, Path.GetPathRoot(packageRoot));
        if (!string.Equals(Sha256File(script), args[5], StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(Sha256File(typeof(UpdateSessionTaskHost).Assembly.Location), args[6], StringComparison.OrdinalIgnoreCase)) return 21;
        string arguments = Encoding.UTF8.GetString(Convert.FromBase64String(args[3]));
        if (arguments.IndexOf('\0') >= 0 || arguments.IndexOf('\r') >= 0 || arguments.IndexOf('\n') >= 0) return 22;
        string quotedScript = "\"" + System.Text.RegularExpressions.Regex.Escape(script) + "\"";
        string eventSuffix = " -ParentProcessId [1-9][0-9]* -ParentProcessStartTimeFileTimeUtc [1-9][0-9]*" +
            " -ReadyEventName \"Local\\\\ChatGPTCustomLauncher-Ready-[0-9a-f]{32}\"" +
            " -RejectedEventName \"Local\\\\ChatGPTCustomLauncher-Rejected-[0-9a-f]{32}\"";
        string pattern = string.Equals(Path.GetFileName(script), "MobileProjectStartup.ps1", StringComparison.Ordinal)
            ? "^-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + quotedScript +
              " -Action Run(?: -UseProxy)?(?: -ReplaceRunningApp)?" + eventSuffix + "$"
            : "^-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + quotedScript + eventSuffix + "$";
        if (!System.Text.RegularExpressions.Regex.IsMatch(arguments, pattern, System.Text.RegularExpressions.RegexOptions.CultureInvariant)) return 22;
        var start = new ProcessStartInfo {
            FileName = powershell, Arguments = arguments, WorkingDirectory = Path.GetDirectoryName(script),
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
        };
        start.EnvironmentVariables.Remove("PSModulePath");
        UseStableUserTemporaryDirectory(start);
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return 23;
        var limits = new ExtendedLimitInformation();
        limits.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) { CloseHandle(job); return 24; }
        try
        {
            using (Process process = Process.Start(start))
            {
                if (process == null || !AssignProcessToJobObject(job, process.Handle))
                {
                    try { if (process != null && !process.HasExited) process.Kill(); } catch { }
                    return 25;
                }
                process.WaitForExit();
                int exitCode = process.ExitCode;
                limits.BasicLimitInformation.LimitFlags = 0;
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation))))
                {
                    // Keep the host and job handle alive rather than killing a
                    // successfully launched descendant when the handle closes.
                    while (true) System.Threading.Thread.Sleep(60000);
                }
                return exitCode;
            }
        }
        finally { CloseHandle(job); }
    }

    private static void WriteIdentity(string path, string nonce, Process process)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string json = string.Format(
            "{{\"nonce\":\"{0}\",\"pid\":{1},\"startTimeFileTimeUtc\":\"{2}\"}}\r\n",
            nonce, process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc());
        File.WriteAllText(temporary, json, new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(temporary, path);
    }

    public static int Main(string[] args)
    {
        if (args.Length > 0 && string.Equals(args[0], "--worker", StringComparison.Ordinal))
        {
            try { return RunWorker(args); } catch { return 19; }
        }
        if (args.Length != 8) return 2;
        try
        {
            string node = FullPath(args[0]);
            string script = FullPath(args[1]);
            string config = FullPath(args[2]);
            string configHash = args[3].ToLowerInvariant();
            string nodeHash = args[4].ToLowerInvariant();
            string scriptHash = args[5].ToLowerInvariant();
            string identity = FullPath(args[6]);
            string nonce = args[7].ToLowerInvariant();
            if (!System.Text.RegularExpressions.Regex.IsMatch(configHash, "^[0-9a-f]{64}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(nodeHash, "^[0-9a-f]{64}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(scriptHash, "^[0-9a-f]{64}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(nonce, "^[0-9a-f]{64}$")) return 3;
            string stateRoot = FullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"ChatGPTRemoteEnabler\update-sessions"));
            string bundleRoot = Path.GetDirectoryName(script);
            string sessionRoot = Path.GetDirectoryName(config);
            if (!string.Equals(Path.GetFileName(script), "update-session.js", StringComparison.Ordinal) ||
                !string.Equals(Path.GetFileName(config), "session.json", StringComparison.Ordinal) ||
                !string.Equals(Path.GetFileName(identity), "coordinator-identity.json", StringComparison.Ordinal) ||
                !IsDirectChild(Path.Combine(stateRoot, "bundles"), bundleRoot) ||
                !IsDirectChild(Path.Combine(stateRoot, "sessions"), sessionRoot) ||
                !IsDirectChild(sessionRoot, identity) ||
                !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(bundleRoot), "^[0-9a-f]{64}$") ||
                !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(sessionRoot), "^[0-9a-f]{32}$")) return 4;
            AssertNoReparseThrough(script, stateRoot);
            AssertNoReparseThrough(config, stateRoot);
            if ((File.GetAttributes(node) & FileAttributes.ReparsePoint) != 0) return 4;
            if (!string.Equals(Sha256File(node), nodeHash, StringComparison.Ordinal) ||
                !string.Equals(Sha256File(script), scriptHash, StringComparison.Ordinal) ||
                !string.Equals(Sha256File(config), configHash, StringComparison.Ordinal)) return 5;
            var start = new ProcessStartInfo
            {
                FileName = node,
                Arguments = "--no-warnings " + QuoteArgument(script) + " --config " + QuoteArgument(config) +
                    " --best-effort --expected-config-sha256 " + configHash,
                WorkingDirectory = bundleRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            UseStableUserTemporaryDirectory(start);
            using (Process process = Process.Start(start))
            {
                if (process == null) return 6;
                string actual = ProcessImagePath(process);
                if (!string.Equals(actual, node, StringComparison.OrdinalIgnoreCase))
                {
                    try { if (!process.HasExited) process.Kill(); } catch { }
                    return 7;
                }
                try { WriteIdentity(identity, nonce, process); }
                catch
                {
                    try { if (!process.HasExited) process.Kill(); } catch { }
                    return 8;
                }
                System.Threading.Thread.Sleep(250);
                return 0;
            }
        }
        catch { return 1; }
    }
}
