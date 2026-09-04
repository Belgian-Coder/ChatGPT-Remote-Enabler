using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class PackageProcessLauncher
{
    private sealed class BridgeSession : IDisposable
    {
        public Process Process { get; private set; }
        public int Port { get; private set; }

        public BridgeSession(Process process, int port)
        {
            Process = process;
            Port = port;
        }

        public void Dispose()
        {
            try
            {
                if (Process != null && !Process.HasExited) Process.Kill();
            }
            catch
            {
                // The bridge may already have observed this launcher's exit.
            }
            finally
            {
                if (Process != null) Process.Dispose();
            }
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length == 0) return "\"\"";
        bool needsQuotes = false;
        foreach (char character in value)
        {
            if (char.IsWhiteSpace(character) || character == '"')
            {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes) return value;

        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static Uri ValidateProxy(string value)
    {
        Uri proxy;
        if (!Uri.TryCreate(value, UriKind.Absolute, out proxy) ||
            (proxy.Scheme != Uri.UriSchemeHttp && proxy.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrWhiteSpace(proxy.Host) ||
            !string.IsNullOrEmpty(proxy.UserInfo) ||
            (proxy.AbsolutePath != string.Empty && proxy.AbsolutePath != "/") ||
            !string.IsNullOrEmpty(proxy.Query) ||
            !string.IsNullOrEmpty(proxy.Fragment))
        {
            throw new ArgumentException("The environment proxy is invalid.");
        }
        return proxy;
    }

    private static Uri ValidateTarget(string value)
    {
        Uri target;
        if (!Uri.TryCreate(value, UriKind.Absolute, out target) ||
            target.Scheme != Uri.UriSchemeHttps ||
            string.IsNullOrWhiteSpace(target.Host) ||
            !string.IsNullOrEmpty(target.UserInfo) ||
            (target.AbsolutePath != string.Empty && target.AbsolutePath != "/") ||
            !string.IsNullOrEmpty(target.Query) ||
            !string.IsNullOrEmpty(target.Fragment))
        {
            throw new ArgumentException("The API bridge target is invalid.");
        }
        return target;
    }

    private static string RequireFile(string value, string label)
    {
        string path = Path.GetFullPath(value);
        if (!File.Exists(path)) throw new FileNotFoundException(label + " was not found.");
        return path;
    }

    private static BridgeSession StartBridge(string nodePath, string bridgePath, string proxyUrl, string targetUrl, string token)
    {
        var start = new ProcessStartInfo
        {
            FileName = nodePath,
            Arguments = string.Join(" ", new [] {
                QuoteArgument(bridgePath),
                "--proxy", QuoteArgument(proxyUrl),
                "--target", QuoteArgument(targetUrl),
                "--token", QuoteArgument(token),
                "--parent-pid", Process.GetCurrentProcess().Id.ToString()
            }),
            WorkingDirectory = Path.GetDirectoryName(bridgePath),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        Process bridge = Process.Start(start);
        if (bridge == null) throw new InvalidOperationException("The API proxy bridge did not start.");
        try
        {
            var readyTask = bridge.StandardOutput.ReadLineAsync();
            if (!readyTask.Wait(10000)) throw new TimeoutException("The API proxy bridge did not become ready.");
            string ready = readyTask.Result ?? string.Empty;
            int port;
            if (!ready.StartsWith("READY ", StringComparison.Ordinal) ||
                !int.TryParse(ready.Substring(6), out port) || port < 1 || port > 65535)
            {
                string detail = bridge.HasExited ? bridge.StandardError.ReadToEnd().Trim() : string.Empty;
                throw new InvalidOperationException("The API proxy bridge returned an invalid readiness response." +
                    (detail.Length == 0 ? string.Empty : " " + detail));
            }
            return new BridgeSession(bridge, port);
        }
        catch
        {
            try { if (!bridge.HasExited) bridge.Kill(); } catch { }
            bridge.Dispose();
            throw;
        }
    }

    private static string EnsureLoopbackBypass(string upper, string lower)
    {
        const string loopback = "localhost,127.0.0.1,::1";
        string current = string.IsNullOrWhiteSpace(lower) ? upper : lower;
        return string.IsNullOrWhiteSpace(current) ? loopback : current + "," + loopback;
    }

    public static int Main(string[] args)
    {
        if (args.Length < 5)
        {
            Console.Error.WriteLine("Usage: PackageProcessLauncher.exe <executable> <proxy-url> <node> <bridge-script> <target-url> [arguments ...]");
            return 2;
        }

        try
        {
            string executable = Path.GetFullPath(args[0]);
            if (!File.Exists(executable)) throw new FileNotFoundException("The packaged executable was not found.");
            Uri proxy = ValidateProxy(args[1]);
            string proxyUrl = proxy.GetLeftPart(UriPartial.Authority);
            string nodePath = RequireFile(args[2], "The Node.js runtime");
            string bridgePath = RequireFile(args[3], "The API proxy bridge");
            Uri target = ValidateTarget(args[4]);
            string targetUrl = target.GetLeftPart(UriPartial.Authority);
            var launchArguments = new string[Math.Max(0, args.Length - 5)];
            if (launchArguments.Length > 0) Array.Copy(args, 5, launchArguments, 0, launchArguments.Length);
            string token = Guid.NewGuid().ToString("N");

            using (BridgeSession bridge = StartBridge(nodePath, bridgePath, proxyUrl, targetUrl, token))
            {
                var start = new ProcessStartInfo
                {
                    FileName = executable,
                    Arguments = string.Join(" ", Array.ConvertAll(launchArguments, QuoteArgument)),
                    WorkingDirectory = Path.GetDirectoryName(executable),
                    UseShellExecute = false
                };
                start.EnvironmentVariables["HTTP_PROXY"] = proxyUrl;
                start.EnvironmentVariables["HTTPS_PROXY"] = proxyUrl;
                start.EnvironmentVariables["http_proxy"] = proxyUrl;
                start.EnvironmentVariables["https_proxy"] = proxyUrl;
                start.EnvironmentVariables["NODE_USE_ENV_PROXY"] = "1";
                start.EnvironmentVariables["CODEX_API_BASE_URL"] = string.Format(
                    "http://127.0.0.1:{0}/{1}/backend-api", bridge.Port, token);
                string noProxy = EnsureLoopbackBypass(
                    start.EnvironmentVariables["NO_PROXY"],
                    start.EnvironmentVariables["no_proxy"]);
                start.EnvironmentVariables["NO_PROXY"] = noProxy;
                start.EnvironmentVariables["no_proxy"] = noProxy;

                using (Process child = Process.Start(start))
                {
                    if (child == null) throw new InvalidOperationException("The packaged process did not start.");
                    Console.WriteLine(child.Id);
                    child.WaitForExit();
                    return child.ExitCode;
                }
            }
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.GetType().FullName + ": " + exception.Message);
            return 1;
        }
    }
}
