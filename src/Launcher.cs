using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security;
using System.Text;
using System.Threading;

namespace SpicetifyManager
{
    internal static class Launcher
    {
        [STAThread]
        private static int Main(string[] arguments)
        {
            Encoding previousEncoding = Console.OutputEncoding;
            try
            {
                Console.OutputEncoding = new UTF8Encoding(false);
                return Run(arguments);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("ERROR: The Windows PowerShell 5.1 host could not run. " + error.Message);
                return 70;
            }
            finally { Console.OutputEncoding = previousEncoding; }
        }

        // The CLR supplies the native argument array. Never quote, join, expand,
        // or pass it to another process. Only repository-owned source is code.
        private static int Run(string[] arguments)
        {
            Environment.SetEnvironmentVariable("PSModulePath", null);
            string source;
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("SpicetifyManager.Manager.ps1"))
            {
                if (stream == null) throw new InvalidDataException("The embedded manager source is missing.");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true))) source = reader.ReadToEnd();
            }
            var host = new ManagerHost();
            using (Runspace runspace = RunspaceFactory.CreateRunspace(host))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell engine = PowerShell.Create())
                {
                    engine.Runspace = runspace;
                    engine.AddScript(source, true).AddParameter("NativeArguments", arguments).AddCommand("Out-Default");
                    bool cancelled = false;
                    ConsoleCancelEventHandler cancel = delegate(object sender, ConsoleCancelEventArgs e)
                    {
                        e.Cancel = true;
                        cancelled = true;
                        try { engine.Stop(); } catch (InvalidOperationException) { }
                    };
                    Console.CancelKeyPress += cancel;
                    try
                    {
                        engine.Invoke();
                        foreach (ErrorRecord error in engine.Streams.Error) host.UI.WriteErrorLine(error.ToString());
                        if (cancelled) return 130;
                        if (host.ExitRequested) return host.ExitCode;
                        return engine.HadErrors ? 70 : 0;
                    }
                    catch (PipelineStoppedException) { return cancelled ? 130 : 70; }
                    finally { Console.CancelKeyPress -= cancel; }
                }
            }
        }
    }

    // Console hosting preserves the existing menu without a child shell.
    internal sealed class ManagerHost : PSHost
    {
        private readonly Guid id = Guid.NewGuid();
        private readonly ManagerUI ui = new ManagerUI();
        internal bool ExitRequested { get; private set; }
        internal int ExitCode { get; private set; }
        public override Guid InstanceId { get { return id; } }
        public override string Name { get { return "SpicetifySpotifyManager"; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override PSHostUserInterface UI { get { return ui; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.CurrentCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.CurrentUICulture; } }
        public override void SetShouldExit(int exitCode) { ExitCode = exitCode; ExitRequested = true; }
        public override void EnterNestedPrompt() { throw new NotSupportedException("Nested prompts are not supported."); }
        public override void ExitNestedPrompt() { throw new NotSupportedException("Nested prompts are not supported."); }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }

    internal sealed class ManagerUI : PSHostUserInterface
    {
        private readonly ManagerRawUI raw = new ManagerRawUI();
        public override PSHostRawUserInterface RawUI { get { return raw; } }
        public override string ReadLine() { return Console.ReadLine() ?? ""; }
        public override SecureString ReadLineAsSecureString() { throw new NotSupportedException("This manager does not request credentials."); }
        public override void Write(string value) { Console.Write(value); }
        public override void WriteLine(string value) { Console.WriteLine(value); }
        public override void Write(ConsoleColor foreground, ConsoleColor background, string value)
        {
            if (Console.IsOutputRedirected) { Write(value); return; }
            var oldForeground = Console.ForegroundColor;
            var oldBackground = Console.BackgroundColor;
            try { Console.ForegroundColor = foreground; Console.BackgroundColor = background; Write(value); }
            finally { Console.ForegroundColor = oldForeground; Console.BackgroundColor = oldBackground; }
        }
        public override void WriteErrorLine(string value) { Console.Error.WriteLine(value); }
        public override void WriteDebugLine(string value) { Console.Error.WriteLine(value); }
        public override void WriteVerboseLine(string value) { Console.Error.WriteLine(value); }
        public override void WriteWarningLine(string value) { Console.Error.WriteLine("WARNING: " + value); }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> fields)
        {
            if (!string.IsNullOrEmpty(caption)) WriteLine(caption);
            if (!string.IsNullOrEmpty(message)) WriteLine(message);
            var result = new Dictionary<string, PSObject>();
            foreach (FieldDescription field in fields) { Write(field.Name + ": "); result.Add(field.Name, PSObject.AsPSObject(ReadLine())); }
            return result;
        }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            WriteLine(caption); WriteLine(message);
            for (int index = 0; index < choices.Count; index++) WriteLine(index + ": " + choices[index].Label);
            int selected;
            string answer = ReadLine();
            if (answer.Length == 0) return defaultChoice;
            if (int.TryParse(answer, out selected) && selected >= 0 && selected < choices.Count) return selected;
            throw new ArgumentException("Invalid choice.");
        }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
        { throw new NotSupportedException("This manager does not request credentials."); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options)
        { throw new NotSupportedException("This manager does not request credentials."); }
    }

    internal sealed class ManagerRawUI : PSHostRawUserInterface
    {
        public override ConsoleColor BackgroundColor { get { return Console.BackgroundColor; } set { if (!Console.IsOutputRedirected) Console.BackgroundColor = value; } }
        public override ConsoleColor ForegroundColor { get { return Console.ForegroundColor; } set { if (!Console.IsOutputRedirected) Console.ForegroundColor = value; } }
        public override Size BufferSize { get { return Console.IsOutputRedirected ? new Size(120, 40) : new Size(Console.BufferWidth, Console.BufferHeight); } set { Console.SetBufferSize(value.Width, value.Height); } }
        public override Coordinates CursorPosition { get { return Console.IsOutputRedirected ? new Coordinates(0, 0) : new Coordinates(Console.CursorLeft, Console.CursorTop); } set { if (!Console.IsOutputRedirected) Console.SetCursorPosition(value.X, value.Y); } }
        public override int CursorSize { get { return Console.CursorSize; } set { Console.CursorSize = value; } }
        public override bool KeyAvailable { get { return !Console.IsInputRedirected && Console.KeyAvailable; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(Console.LargestWindowWidth, Console.LargestWindowHeight); } }
        public override Size MaxWindowSize { get { return MaxPhysicalWindowSize; } }
        public override Coordinates WindowPosition { get { return new Coordinates(Console.WindowLeft, Console.WindowTop); } set { Console.SetWindowPosition(value.X, value.Y); } }
        public override Size WindowSize { get { return Console.IsOutputRedirected ? new Size(120, 40) : new Size(Console.WindowWidth, Console.WindowHeight); } set { Console.SetWindowSize(value.Width, value.Height); } }
        public override string WindowTitle { get { return Console.Title; } set { if (!Console.IsOutputRedirected) Console.Title = value; } }
        public override void FlushInputBuffer() { while (KeyAvailable) Console.ReadKey(true); }
        public override KeyInfo ReadKey(ReadKeyOptions options) { throw new NotSupportedException("Use the manager's line-based menu."); }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) { throw new NotSupportedException(); }
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { throw new NotSupportedException(); }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { throw new NotSupportedException(); }
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill)
        {
            if (rectangle.Left != -1 || rectangle.Top != -1) throw new NotSupportedException();
            if (!Console.IsOutputRedirected) Console.Clear();
        }
    }
}
