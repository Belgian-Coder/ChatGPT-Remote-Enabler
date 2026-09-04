using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class PackageProcessLauncher
{
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

    private static string EnsureLoopbackBypass(string upper, string lower)
    {
        const string loopback = "localhost,127.0.0.1,::1";
        string current = string.IsNullOrWhiteSpace(lower) ? upper : lower;
        return string.IsNullOrWhiteSpace(current) ? loopback : current + "," + loopback;
    }

    public static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: PackageProcessLauncher.exe <executable> <proxy-url> [arguments ...]");
            return 2;
        }

        try
        {
            string executable = Path.GetFullPath(args[0]);
            if (!File.Exists(executable)) throw new FileNotFoundException("The packaged executable was not found.");
            Uri proxy = ValidateProxy(args[1]);
            string proxyUrl = proxy.GetLeftPart(UriPartial.Authority);
            var launchArguments = new string[Math.Max(0, args.Length - 2)];
            if (launchArguments.Length > 0) Array.Copy(args, 2, launchArguments, 0, launchArguments.Length);

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
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.GetType().FullName + ": " + exception.Message);
            return 1;
        }
    }
}
