using System;
using System.Runtime.InteropServices;

internal static class PackageActivationLauncher
{
    [Flags]
    private enum ActivateOptions
    {
        None = 0
    }

    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    private class ApplicationActivationManager
    {
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);

        [PreserveSig]
        int ActivateForFile(IntPtr appUserModelId, IntPtr itemArray, IntPtr verb, out uint processId);

        [PreserveSig]
        int ActivateForProtocol(IntPtr appUserModelId, IntPtr itemArray, out uint processId);
    }

    public static int Main(string[] args)
    {
        if (args.Length < 1 || args.Length > 2)
        {
            Console.Error.WriteLine("Usage: PackageActivationLauncher.exe <AUMID> [arguments]");
            return 2;
        }

        try
        {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            uint processId;
            string arguments = args.Length == 2 ? args[1] : string.Empty;
            int result = manager.ActivateApplication(args[0], arguments, ActivateOptions.None, out processId);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }

            Console.WriteLine(processId);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.GetType().FullName + ": " + exception.Message);
            Console.Error.WriteLine("HRESULT=0x" + exception.HResult.ToString("X8"));
            return 1;
        }
    }
}
