using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

internal static class SelfContainedBuilder
{
    private sealed class Options
    {
        public string Output;
        public string OllamaPack;
        public string WorkDirectory;
        public bool KeepWorkDirectory;
        public bool DryRun;
        public bool Help;
    }

    private static int Main(string[] args)
    {
        bool pauseWhenDone = args.Length == 0;
        try
        {
            Options options = ParseOptions(args);
            if (options.Help)
            {
                PrintUsage();
                return 0;
            }

            string buildScript = FindBuildScript();
            if (buildScript == null)
                throw new InvalidOperationException(
                    "Build-SelfContained.ps1 was not found. Keep this EXE in the WINDOWS folder of a Hydra source checkout.");

            string windowsDirectory = Path.GetDirectoryName(buildScript);
            string repositoryRoot = Directory.GetParent(windowsDirectory).FullName;
            string output = ResolvePath(
                options.Output ?? Path.Combine("dist", "Hydra-Windows-x64-SelfContained.exe"),
                repositoryRoot);
            string ollamaPack = ResolvePath(
                options.OllamaPack ?? Path.Combine(
                    Path.GetDirectoryName(output), "Hydra-Windows-x64-Ollama-Offline-Pack.zip"),
                repositoryRoot);
            string workDirectory = options.WorkDirectory == null
                ? null
                : ResolvePath(options.WorkDirectory, repositoryRoot);

            Console.WriteLine("Hydra fully self-contained Windows builder");
            Console.WriteLine("Builder script: " + buildScript);
            Console.WriteLine("Hydra output: " + output);
            Console.WriteLine("Ollama pack: " + ollamaPack);
            if (workDirectory != null) Console.WriteLine("Work directory: " + workDirectory);
            Console.WriteLine();

            if (options.DryRun)
            {
                Console.WriteLine("Dry run: no files were built.");
                return 0;
            }

            Console.WriteLine("The build machine needs internet access to download the pinned, verified payloads.");
            Console.WriteLine("The finished files do not install or download tools on the target PC.");
            Console.WriteLine();

            Directory.CreateDirectory(Path.GetDirectoryName(output));
            Directory.CreateDirectory(Path.GetDirectoryName(ollamaPack));

            var arguments = new List<string>
            {
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", buildScript,
                "-Output", output,
                "-OllamaPackOutput", ollamaPack
            };
            if (workDirectory != null)
            {
                arguments.Add("-WorkDirectory");
                arguments.Add(workDirectory);
            }
            if (options.KeepWorkDirectory) arguments.Add("-KeepWorkDirectory");

            var start = new ProcessStartInfo
            {
                FileName = FindWindowsPowerShell(),
                Arguments = JoinArguments(arguments),
                WorkingDirectory = repositoryRoot,
                UseShellExecute = false
            };
            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("The self-contained build failed with exit code " + process.ExitCode + ".");
            }

            Console.WriteLine();
            Console.WriteLine("Build complete. Keep these two files together when copying Hydra to a fresh PC:");
            Console.WriteLine("  " + output);
            Console.WriteLine("  " + ollamaPack);
            return 0;
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine("Error: " + ex.Message);
            Console.Error.WriteLine();
            PrintUsage();
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Build error: " + ex.Message);
            return 1;
        }
        finally
        {
            if (pauseWhenDone)
            {
                Console.WriteLine();
                Console.Write("Press Enter to close...");
                Console.ReadLine();
            }
        }
    }

    private static Options ParseOptions(string[] args)
    {
        var options = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg == "--help" || arg == "-h") options.Help = true;
            else if (arg == "--dry-run") options.DryRun = true;
            else if (arg == "--keep-work-directory") options.KeepWorkDirectory = true;
            else if (arg == "--output") options.Output = ReadValue(args, ref i, arg);
            else if (arg == "--ollama-pack") options.OllamaPack = ReadValue(args, ref i, arg);
            else if (arg == "--work-directory") options.WorkDirectory = ReadValue(args, ref i, arg);
            else throw new ArgumentException("Unknown option: " + arg);
        }
        return options;
    }

    private static string ReadValue(string[] args, ref int index, string option)
    {
        if (index + 1 >= args.Length || String.IsNullOrWhiteSpace(args[index + 1]))
            throw new ArgumentException(option + " requires a value.");
        index++;
        return args[index];
    }

    private static string FindBuildScript()
    {
        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        DirectoryInfo parentDirectory = new DirectoryInfo(baseDirectory).Parent;
        string[] candidates =
        {
            Path.Combine(baseDirectory, "Build-SelfContained.ps1"),
            Path.Combine(baseDirectory, "WINDOWS", "Build-SelfContained.ps1"),
            parentDirectory == null ? "" : Path.Combine(parentDirectory.FullName, "WINDOWS", "Build-SelfContained.ps1")
        };
        foreach (string candidate in candidates)
            if (File.Exists(candidate)) return Path.GetFullPath(candidate);
        return null;
    }

    private static string ResolvePath(string value, string repositoryRoot)
    {
        if (value.IndexOf('"') >= 0) throw new ArgumentException("Paths cannot contain quotation marks: " + value);
        string fullPath = Path.GetFullPath(Path.IsPathRooted(value) ? value : Path.Combine(repositoryRoot, value));
        string root = Path.GetPathRoot(fullPath);
        return fullPath.Length > root.Length
            ? fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            : fullPath;
    }

    private static string FindWindowsPowerShell()
    {
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? "C:\\Windows";
        string bundled = Path.Combine(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(bundled) ? bundled : "powershell.exe";
    }

    private static string JoinArguments(IEnumerable<string> arguments)
    {
        var quoted = new List<string>();
        foreach (string argument in arguments)
        {
            if (argument.IndexOf('"') >= 0) throw new ArgumentException("Arguments cannot contain quotation marks.");
            quoted.Add("\"" + argument + "\"");
        }
        return String.Join(" ", quoted.ToArray());
    }

    private static void PrintUsage()
    {
        Console.WriteLine("Usage: Hydra-SelfContained-Builder.exe [options]");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  --output <path>             Output Hydra EXE path");
        Console.WriteLine("  --ollama-pack <path>        Output Ollama offline-pack path");
        Console.WriteLine("  --work-directory <path>     Temporary build directory");
        Console.WriteLine("  --keep-work-directory       Preserve temporary build files");
        Console.WriteLine("  --dry-run                   Show resolved outputs without building");
        Console.WriteLine("  --help                      Show this help");
        Console.WriteLine();
        Console.WriteLine("With no options, the complete package is written to the repository's dist folder.");
    }
}
