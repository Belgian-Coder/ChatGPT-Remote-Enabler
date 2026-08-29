using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("ChatGPT Remote Enabler")]
[assembly: AssemblyDescription("Starts ChatGPT with the remote access and Mobile projects injection")]
[assembly: AssemblyCompany("Community")]
[assembly: AssemblyProduct("ChatGPT Remote Enabler")]
[assembly: AssemblyVersion("1.5.20.0")]
[assembly: AssemblyFileVersion("1.5.20.0")]

internal static class ChatGPTRemoteLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);

    private static int Fail(int code, string message)
    {
        MessageBox(IntPtr.Zero, message, "ChatGPT Remote Enabler", 0x10);
        return code;
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

        var start = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        try
        {
            using (Process child = Process.Start(start))
            {
                if (child == null) return Fail(4, "Windows PowerShell could not be started.");
                child.WaitForExit();
                if (child.ExitCode != 0) return Fail(child.ExitCode, "ChatGPT Remote Enabler could not complete. See the PowerShell error or the local startup log for details.");
                return 0;
            }
        }
        catch
        {
            return Fail(5, "ChatGPT Remote Enabler failed before Windows PowerShell could complete.");
        }
    }
}
